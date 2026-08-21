
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
