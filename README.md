
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
