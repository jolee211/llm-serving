
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

End to end: 10-15 minutes from scale-up command to first successful completion. Once warm, the smoke-test completion returned near-instantly. Formal p50/p99 and tokens/sec land with the k6 load run (next phase); no latency numbers are claimed here until then.

Why it matters:
- Scale-to-zero saves GPU dollars overnight but buys a 10-15 min cold start every morning. That tradeoff is the whole game for spot-based inference fleets.
- The two big levers are the image pull and the model download, and both are cacheable:
  - Persistent model cache (PVC or S3 sync) instead of `emptyDir`, so weights survive pod restarts.
  - Pre-pulled or node-baked images, so a fresh spot node does not start from a cold registry.
- Spot preemption means this chain can rerun at any time, uninvited. Cold start is not just a morning event, it is the recovery path.
