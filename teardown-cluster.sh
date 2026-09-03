#!/usr/bin/env bash
# Teardown for the disposable lab. Default mode is read-only.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROFILE=personal
REGION=us-east-1
CLUSTER=llm-serving
MODE=plan

case ${1:---plan} in
  --plan) ;;
  --execute) MODE=execute ;;
  -h|--help) echo "Usage: $0 [--plan|--execute]"; exit 0 ;;
  *) echo "Usage: $0 [--plan|--execute]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "too many arguments" >&2; exit 2; }
if [[ ${AWS_PROFILE:-$PROFILE} != "$PROFILE" ]]; then
  echo "refusing to run: use AWS_PROFILE=personal" >&2
  exit 3
fi
export AWS_PROFILE=$PROFILE AWS_REGION=$REGION
"$SCRIPT_DIR/guardrails/verify-zero-cost.sh" --identity-only

quote_command() { printf '%q ' "$@"; }

approve_run() {
  local resource=$1 cost=$2 purpose=$3 consequence=$4 restore=$5
  shift 5
  echo
  echo "Resource: $resource"
  echo "Verified current cost contribution: $cost"
  echo "Project use: $purpose"
  echo "Consequence: $consequence"
  echo "Restoration: $restore"
  printf 'Exact command: '; quote_command "$@"; echo
  if [[ $MODE != execute ]]; then
    echo "PLAN ONLY"
    return 0
  fi
  [[ -t 0 ]] || { echo "refusing non-interactive mutation" >&2; exit 2; }
  if [[ $cost == UNKNOWN* ]]; then
    echo "Dollar cost is unknown. Obtain current billing or pricing evidence before approving." >&2
  fi
  read -r -p "Type approve to run this command: " answer
  [[ $answer == approve ]] || { echo "not approved; stopping" >&2; exit 130; }
  "$@"
}

wait_mount_target_deleted() {
  local mount_target=$1 elapsed=0 state
  while (( elapsed < 600 )); do
    state=$(aws efs describe-mount-targets --profile "$PROFILE" --region "$REGION" \
      --mount-target-id "$mount_target" --query 'MountTargets[0].LifeCycleState' --output text 2>&1) || {
        [[ $state == *MountTargetNotFound* ]] && return 0
        echo "mount-target verification failed" >&2; return 2
      }
    sleep 10; elapsed=$((elapsed + 10))
  done
  echo "timed out waiting for mount target deletion" >&2
  return 2
}

if ! cluster_status=$(aws eks describe-cluster --name "$CLUSTER" --profile "$PROFILE" --region "$REGION" \
  --query 'cluster.status' --output text 2>&1); then
  if [[ $cluster_status == *ResourceNotFoundException* ]]; then
    cluster_status=''
  else
    echo "could not determine cluster state" >&2
    exit 2
  fi
fi
filesystem_candidates=$(aws efs describe-file-systems --profile "$PROFILE" --region "$REGION" \
  --query "FileSystems[?Name=='llm-serving-hf-cache'].FileSystemId" --output text)
filesystems=''
for fs_id in $filesystem_candidates; do
  project_tag=$(aws efs list-tags-for-resource --profile "$PROFILE" --region "$REGION" \
    --resource-id "$fs_id" --query "Tags[?Key=='Project']|[0].Value" --output text)
  [[ $project_tag == llm-serving ]] && filesystems="$filesystems $fs_id"
done
security_groups=$(aws ec2 describe-security-groups --profile "$PROFILE" --region "$REGION" \
  --filters Name=group-name,Values=efs-llm-serving Name=tag:Project,Values=llm-serving \
  --query 'SecurityGroups[].GroupId' --output text)

echo "Teardown plan for $CLUSTER in $REGION"
[[ -n $cluster_status ]] && echo "  EKS cluster: $CLUSTER ($cluster_status)" || echo "  EKS cluster: absent"
[[ -n $filesystems ]] && echo "  EFS filesystems: $filesystems" || echo "  EFS filesystems: absent"
[[ -n $security_groups ]] && echo "  EFS security groups: $security_groups" || echo "  EFS security groups: absent"

for fs_id in $filesystems; do
  fs_state=$(aws efs describe-file-systems --profile "$PROFILE" --region "$REGION" \
    --file-system-id "$fs_id" --query 'FileSystems[0].[LifeCycleState,SizeInBytes.Value]' --output text)
  mount_targets=$(aws efs describe-mount-targets --profile "$PROFILE" --region "$REGION" \
    --file-system-id "$fs_id" --query 'MountTargets[].MountTargetId' --output text)
  for mount_target in $mount_targets; do
    approve_run "EFS mount target $mount_target for $fs_id" \
      "UNKNOWN dollars; state and relationship verified, mount target itself has no hourly fee" \
      "Network attachment for the disposable model cache" \
      "Nodes can no longer mount this cache in that availability zone" \
      "Rebuild creates one mount target per cluster availability zone" \
      aws efs delete-mount-target --profile "$PROFILE" --region "$REGION" --mount-target-id "$mount_target"
    [[ $MODE == execute ]] && wait_mount_target_deleted "$mount_target"
  done
  approve_run "EFS filesystem $fs_id ($fs_state)" \
    "UNKNOWN dollars; live stored bytes shown above, exact current rate requires separate pricing evidence" \
    "Disposable Hugging Face model cache" \
    "Deletes cached weights permanently; benchmark artifacts in Git remain" \
    "Rebuild creates an encrypted filesystem and the model downloads again" \
    aws efs delete-file-system --profile "$PROFILE" --region "$REGION" --file-system-id "$fs_id"
done

for sg_id in $security_groups; do
  approve_run "EFS security group $sg_id" '$0 by itself' \
    "Limits NFS access to the lab cluster" "Removes the EFS network rule" \
    "Rebuild creates and tags a replacement" \
    aws ec2 delete-security-group --profile "$PROFILE" --region "$REGION" --group-id "$sg_id"
done

if [[ -n $cluster_status ]]; then
  nodegroups=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --profile "$PROFILE" \
    --region "$REGION" --query 'nodegroups[]' --output text)
  detail=''
  for nodegroup in $nodegroups; do
    state=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$nodegroup" \
      --profile "$PROFILE" --region "$REGION" \
      --query 'nodegroup.[status,scalingConfig.desiredSize,capacityType,instanceTypes]' --output text)
    detail="$detail $nodegroup=[$state]"
  done
  approve_run "EKS cluster $CLUSTER; node groups:$detail" \
    "UNKNOWN dollars; live states shown, exact current rates require separate billing or pricing evidence" \
    "Kubernetes, monitoring, autoscaling, CPU nodes, and optional GPU nodes" \
    "Deletes the cluster, nodes, managed volumes, control-plane history, and Kubernetes objects" \
    "Run rebuild-cluster.sh; allow 45-60 minutes including first serving start" \
    eksctl delete cluster --name "$CLUSTER" --region "$REGION" --profile "$PROFILE" --wait --timeout 30m
fi

if [[ $MODE == plan ]]; then
  echo "No mutation was performed. Rerun with --execute after reviewing current cost evidence."
  exit 0
fi

echo "Running fail-closed post-teardown verification."
"$SCRIPT_DIR/guardrails/verify-zero-cost.sh"
echo "teardown complete and verified"
