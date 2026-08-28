
## GPU spot capacity note

Symptom:
- `eksctl create nodegroup` timed out behind a vague CloudFormation failure.

Real diagnosis:
- The Auto Scaling Group activity history showed repeated `UnfulfillableCapacity`.
- `g5.xlarge` spot was dry in the two configured AZs.

Fix:
- Widened `instanceTypes` from one type to four:
  - `g5.xlarge`
  - `g6.xlarge`
  - `g5.2xlarge`
  - `g6.2xlarge`
- That expanded the search from 2 spot pools to 8.
- Retry succeeded on `g6.2xlarge`.

Result:
- EKS node joined successfully.
- NVIDIA plugin came up automatically.
- Smoke pod passed with `nvidia-smi` showing an NVIDIA L4 and `nvidia.com/gpu: 1`.

Operational lesson:
- When EKS GPU nodegroup creation times out, check ASG scaling activities before blaming CloudFormation.
- `UnfulfillableCapacity` means broaden spot pools first, then keep an on-demand quota fallback ready.

## Cold start reality

Scaling the GPU nodegroup from 0 to serving traffic is not fast. The observed chain, first boot:

1. Scale ASG 0 to 1, spot request fulfilled: 1-2 min.
2. Node joins the cluster and goes `Ready`: ~2 min.
3. `vllm/vllm-openai:v0.27.1` image pull: several GB, a few minutes.
4. Model download: ~5.5GB of AWQ weights from Hugging Face into an `emptyDir`.
5. vLLM engine init and weight load, then `/health` goes green.

End to end, measured: 10m07s from scale-up command to pod Ready (2026-08-23, fresh spot node, `g6.2xlarge`, timed with `time kubectl wait --for=condition=Ready`). Once warm, the smoke-test completion returned near-instantly. Formal p50/p99 and tokens/sec land with the k6 load run (next phase); no latency numbers are claimed here until then.

Why it matters:
- Scale-to-zero saves GPU dollars overnight but buys a 10-15 min cold start every morning. That tradeoff is the whole game for spot-based inference fleets.
- The two big levers are the image pull and the model download, and both are cacheable:
  - Persistent model cache (PVC or S3 sync) instead of `emptyDir`, so weights survive pod restarts.
  - Pre-pulled or node-baked images, so a fresh spot node does not start from a cold registry.
- Spot preemption means this chain can rerun at any time, uninvited. Cold start is not just a morning event, it is the recovery path.

## Baseline load test (2026-08-23)

Setup:
- `k6`, 8 constant VUs, 3 minutes, chat completions capped at 128 output tokens (actual completions averaged ~49).
- Traffic path: laptop k6 through `kubectl port-forward`, so these are conservative numbers with a known overhead hop. In-cluster k6 job is the follow-up.
- GPU: NVIDIA L4 (`g6.2xlarge` spot). Model: `Qwen/Qwen2.5-7B-Instruct-AWQ` on vLLM `v0.27.1`.

Results:
- 1,376 completions, 0 failures, 7.6 req/s sustained.
- Latency p50 1.06s, p90 1.24s, p95 1.31s (k6). Prometheus e2e p95 1.45s (coarser histogram buckets, no port-forward hop excluded).
- Time to first token p95: ~60ms.
- Peak generation throughput: ~374 tokens/sec (1m rate of `vllm:generation_tokens_total`).
- Peak KV cache usage: 0.14%.

Reading:
- 8 concurrent requests nowhere near saturates the L4. KV cache under 1% and 60ms TTFT mean requests barely queue.
- This run establishes the healthy baseline, not capacity. The knee point (where latency degrades as VUs climb) is the real single-GPU capacity number. Next run: 32 and 64 VUs, in-cluster.

## Knee-point sweep (2026-08-24)

Setup:
- k6 as an in-cluster Job (`k6-job.yaml` + `run-knee-sweep.sh`), 3 minutes per level, same 128-max-token chat workload (~49 actual tokens per completion).
- GPU: NVIDIA A10G (`g5.xlarge`, on-demand fallback nodegroup; spot was dry that day, see below). Different card than the 08-23 baseline (L4), so the two runs are not directly comparable.

| VUs | req/s | p50    | p95    | gen tok/s | TTFT p95 | KV cache max |
|----:|------:|-------:|-------:|----------:|---------:|-------------:|
|   8 |  14.3 |  567ms |  708ms |       704 |     39ms |         0.2% |
|  16 |  26.3 |  617ms |  771ms |     1,294 |     39ms |         0.3% |
|  32 |  41.7 |  774ms |  963ms |     2,054 |     59ms |         0.5% |
|  64 |  43.3 |  1.49s |  1.88s |     2,123 |     99ms |         1.0% |

Findings:
- Knee sits between 32 and 64 concurrent: 64 VUs buys +3% throughput for +95% p95. Operating point: 32 concurrent, ~42 req/s, ~2,050 tok/s, p95 under 1s.
- `vllm:num_requests_waiting` stayed at 0 through the whole sweep. vLLM's continuous batching admits everything and degrades per-token speed instead of queueing. Autoscaling on queue depth would never trigger for this workload shape; scale on running-request count or inter-token latency instead.
- Port-forward overhead was real: the same 8-VU load ran at 14.3 req/s in-cluster vs 7.6 req/s through `kubectl port-forward`, at roughly half the p95. Never benchmark through a port-forward.
- Workload caveat: ~49-token completions never touch KV cache (1% peak). This knee is compute-bound; long-context workloads would hit memory first and knee earlier.

Cost per million generated tokens (price assumption: `g5.xlarge` on-demand us-east-1 at ~$1.01/hr; spot varies ~$0.35-0.50/hr):
- At the 2,054 tok/s operating point: ~7.4M tokens/hr, so roughly $0.14/M tokens on-demand, $0.05-0.07/M on spot.
- Generation tokens only; prompt tokens excluded (negligible in this workload).

## KEDA autoscaling (2026-08-26/27)

Autoscaling on inference-native signals, per the knee-sweep finding: continuous batching means `num_requests_waiting` stays at 0 while per-token speed degrades, so queue depth is the wrong trigger. Scale on running-request count instead.

ScaledObject (`vllm-scaledobject.yaml`): Prometheus trigger on `sum(vllm:num_requests_running)`, threshold 24 (75% of the measured knee at 32), minReplicas 1, maxReplicas 2, cooldown 300s.

### What happened live (2026-08-26)

- 64-VU load: HPA saw 64/24 within one 15s poll, desired went to 2. Per-pod average settled ~31, right at the operating point. The policy math worked exactly as designed.
- **Thrash cycle, observed:** the 3-min load ended inside the new replica's cold start. Cooldown (300s) fired before the pod went Ready, and KEDA killed it mid-warmup. The replica died in `Error` having never served a request. Cooldown shorter than worst-case cold start is pure waste: you pay for the GPU node and get zero requests out of it.
- **Warm-node scale-out, measured:** a second scale-out landed on a node that already had the vLLM image cached: pod Ready in 2m50s vs ~10 min on a fresh node. Image caching is worth ~7 min; the remaining ~3 min is the model download (per-pod `emptyDir`).

Timeline screenshots: `keda-loadtest-dashboard.png` (both cycles, all serving metrics), `keda-thrash-timeline.png` (desired vs ready replicas with the thrash visible).

### Clean 1-vs-2 replica comparison (2026-08-27, same day, warm pods, 64 VUs, 3 min each)

| Replicas | req/s | p95 e2e | Failures | Notes |
|---|---|---|---|---|
| 1 | 43.2 | 1.87s | 0 | Saturated; reproduces the 08-24 knee-sweep 64-VU result (43 req/s, 1.88s) |
| 2 | 81.0 | 1.05s | 0 | Load split 26/35 running requests across pods |

1.87x throughput at 2 replicas with p95 cut 44%. Near-linear, as expected for replica-parallel serving with a service-level round-robin. Screenshot: `keda-1v2-replica-comparison.png` (2-replica run left, 1-replica run right).

Also observed: two pods cold-starting in parallel on two fresh on-demand nodes both went Ready in 8m28s from the scale command (~7m20s pod-to-Ready each). Parallel cold start does not stack; the fleet warms in one cold-start window, not N.

### Mitigations (ranked)

1. **Cooldown > worst-case cold start.** 300s cooldown vs ~10 min cold start guarantees thrash on short bursts. Set cooldown (or a scale-in stabilization window) above the measured worst-case Ready time, ~900s here.
2. **Model cache on a PVC** instead of per-pod `emptyDir`: kills the ~3 min re-download on every pod start. Next planned change.
3. **Pre-pulled images** (DaemonSet warmer or baked AMI): kills the ~7 min pull on fresh nodes.
4. **Business-hours minReplicas** if traffic has a known floor: the cheapest latency insurance is a replica that already exists.
5. Karpenter for right-sized GPU node provisioning: future work.

## GPU capacity events log

- 2026-08-20/21: `g5.xlarge` spot dry in both AZs (`UnfulfillableCapacity`). Fixed by widening 2 pools to 8 (4 types x 2 AZs).
- 2026-08-24: all 8 spot pools dry, and g6 (L4) on-demand also dry in both AZs. A10G on-demand available. Lessons:
  - Spot and on-demand draw from the same physical pools. An on-demand quota is a hedge against spot reclaim and pricing, not against regional hardware scarcity. Capacity independence requires different families, AZs, or regions.
  - On-demand managed nodegroups appeared to retry only the first entry of `instanceTypes` rather than falling back down the list (observed via ASG scaling activities; not documented behavior). Fix was reordering the list to lead with the available family.
  - Keep a pre-approved on-demand fallback nodegroup config in the repo (`gpu-od-nodegroup.yaml`), scaled to 0. On the drought day it was one command to activate.
