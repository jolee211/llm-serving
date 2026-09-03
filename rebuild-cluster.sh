#!/usr/bin/env bash
# Rebuild the disposable lab, including EFS. Default mode is read-only.
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
[[ $MODE != execute ]] || "$SCRIPT_DIR/guardrails/verify-zero-cost.sh"

version=$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["metadata"]["version"])' "$SCRIPT_DIR/cluster.yaml")
support=$(aws eks describe-cluster-versions --cluster-versions "$version" --profile "$PROFILE" \
  --region "$REGION" --query 'clusterVersions[0].versionStatus' --output text)
[[ $support == STANDARD_SUPPORT ]] || {
  echo "refusing to create Kubernetes $version: support status is $support" >&2
  exit 2
}

expires_at=$(date -u -v+1d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/llm-serving-rebuild.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

python3 - "$SCRIPT_DIR" "$temp_dir" "$expires_at" <<'PY'
from pathlib import Path
import sys, yaml
source, target, expires = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
tags = {"Project": "llm-serving", "Owner": "Joseph", "Environment": "personal-lab", "ExpiresAt": expires}
for name in ("cluster.yaml", "gpu-nodegroup.yaml", "gpu-od-nodegroup.yaml"):
    data = yaml.safe_load((source / name).read_text(encoding="utf-8"))
    data.setdefault("metadata", {}).setdefault("tags", {}).update(tags)
    for group in data.get("managedNodeGroups", []): group.setdefault("tags", {}).update(tags)
    (target / name).write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
PY

quote_command() { printf '%q ' "$@"; }

approve_run() {
  local resource=$1 cost=$2 purpose=$3 consequence=$4 restore=$5
  shift 5
  echo
  echo "Resource: $resource"
  echo "Current cost contribution: $cost"
  echo "Purpose: $purpose"
  echo "Consequence: $consequence"
  echo "Restoration: $restore"
  printf 'Exact command: '; quote_command "$@"; echo
  if [[ $MODE != execute ]]; then
    echo "PLAN ONLY"
    return 0
  fi
  [[ -t 0 ]] || { echo "refusing non-interactive mutation" >&2; exit 2; }
  read -r -p "Type approve to run this command: " answer
  [[ $answer == approve ]] || { echo "not approved; stopping" >&2; exit 130; }
  "$@"
}

echo "Plan: rebuild $CLUSTER in $REGION; GPU node groups remain at zero."
echo "Estimated four-hour session: about \$5 before tax, last verified 2026-09-02."
echo "Every resource receives an expiration tag of $expires_at."

approve_run "EKS cluster $CLUSTER and two CPU nodes" \
  '$0 before creation; prior verified baseline was about $4.40/day' \
  "Run Kubernetes, monitoring, and autoscaling experiments" \
  "Starts an EKS control plane and two t3.medium nodes; no GPU starts" \
  "Preserve results, then run teardown-cluster.sh" \
  eksctl create cluster -f "$temp_dir/cluster.yaml" --profile "$PROFILE"

approve_run "local kubeconfig context personal-llm-serving" '$0' \
  "Pin kubectl to this personal cluster" "Changes the current local context" \
  "Select the prior context with kubectl config use-context" \
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --profile "$PROFILE" --alias personal-llm-serving

approve_run "GPU Spot node group gpu-spot at desired size 0" \
  '$0 compute while desired size is 0' "Retain repeatable Spot experiments" \
  "Creates a zero-capacity node-group stack" "Deleted with the cluster" \
  eksctl create nodegroup --config-file "$temp_dir/gpu-nodegroup.yaml" --profile "$PROFILE"

approve_run "GPU on-demand node group gpu-od at desired size 0" \
  '$0 compute while desired size is 0' "Provide a capacity fallback" \
  "Creates a zero-capacity node-group stack" "Deleted with the cluster" \
  eksctl create nodegroup --config-file "$temp_dir/gpu-od-nodegroup.yaml" --profile "$PROFILE"

if [[ $MODE == plan ]]; then
  cat <<'EOF'

Execution then discovers the created VPC and explicitly approves:
  encrypted EFS cache; security group and NFS rule; one mount target per AZ;
  Prometheus/Grafana; KEDA; cache, vLLM, ServiceMonitor, ScaledObject, dashboard.
No mutation was performed.
EOF
  exit 0
fi

vpc_id=$(aws eks describe-cluster --name "$CLUSTER" --profile "$PROFILE" --region "$REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
cluster_sg=$(aws eks describe-cluster --name "$CLUSTER" --profile "$PROFILE" --region "$REGION" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
subnets=$(aws eks describe-cluster --name "$CLUSTER" --profile "$PROFILE" --region "$REGION" --query 'cluster.resourcesVpcConfig.subnetIds[]' --output text | tr '\t' ' ')

approve_run "encrypted EFS filesystem llm-serving-hf-cache" \
  '$0 before creation; storage and elastic-throughput access become billable' \
  "Share the model cache across GPU nodes" "Creates disposable cache storage" \
  "Rebuild and repopulate it later" \
  aws efs create-file-system --profile "$PROFILE" --region "$REGION" \
    --creation-token "llm-serving-hf-cache-$(date +%s)" --encrypted \
    --performance-mode generalPurpose --throughput-mode elastic --no-backup \
    --tags Key=Name,Value=llm-serving-hf-cache Key=Project,Value=llm-serving \
           Key=Owner,Value=Joseph Key=Environment,Value=personal-lab Key=ExpiresAt,Value="$expires_at"

fs_id=$(aws efs describe-file-systems --profile "$PROFILE" --region "$REGION" --query "FileSystems[?Name=='llm-serving-hf-cache']|[0].FileSystemId" --output text)
[[ $fs_id == fs-* ]] || { echo "new EFS filesystem not found" >&2; exit 2; }
elapsed=0
while (( elapsed < 300 )); do
  fs_status=$(aws efs describe-file-systems --profile "$PROFILE" --region "$REGION" \
    --file-system-id "$fs_id" --query 'FileSystems[0].LifeCycleState' --output text)
  [[ $fs_status == available ]] && break
  [[ $fs_status == creating ]] || { echo "unexpected EFS state: $fs_status" >&2; exit 2; }
  sleep 10; elapsed=$((elapsed + 10))
done
[[ $fs_status == available ]] || { echo "timed out waiting for EFS availability" >&2; exit 2; }

approve_run "security group efs-llm-serving in $vpc_id" '$0 by itself' \
  "Limit NFS access to this cluster" "Creates one security group" \
  "Teardown deletes it before the cluster" \
  aws ec2 create-security-group --profile "$PROFILE" --region "$REGION" \
    --group-name efs-llm-serving --description "NFS for llm-serving EFS cache" --vpc-id "$vpc_id" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=llm-serving},{Key=Owner,Value=Joseph},{Key=Environment,Value=personal-lab},{Key=ExpiresAt,Value=$expires_at}]"

efs_sg=$(aws ec2 describe-security-groups --profile "$PROFILE" --region "$REGION" \
  --filters Name=group-name,Values=efs-llm-serving Name=vpc-id,Values="$vpc_id" \
  --query 'SecurityGroups[0].GroupId' --output text)
approve_run "NFS ingress on $efs_sg from $cluster_sg" '$0' \
  "Allow cluster nodes to mount EFS" "Opens TCP 2049 only from the cluster group" \
  "Deleting the EFS group removes the rule" \
  aws ec2 authorize-security-group-ingress --profile "$PROFILE" --region "$REGION" \
    --group-id "$efs_sg" --protocol tcp --port 2049 --source-group "$cluster_sg"

seen_az=' '
for subnet in $subnets; do
  az=$(aws ec2 describe-subnets --profile "$PROFILE" --region "$REGION" --subnet-ids "$subnet" --query 'Subnets[0].AvailabilityZone' --output text)
  case "$seen_az" in *" $az "*) continue ;; esac
  seen_az="$seen_az$az "
  approve_run "EFS mount target for $fs_id in $subnet ($az)" \
    '$0 hourly; EFS access can be billable' "Mount the cache in this AZ" \
    "Creates an EFS network interface" "Teardown deletes it first" \
    aws efs create-mount-target --profile "$PROFILE" --region "$REGION" \
      --file-system-id "$fs_id" --subnet-id "$subnet" --security-groups "$efs_sg"
done

python3 - "$SCRIPT_DIR/hf-cache-pv.yaml" "$temp_dir/hf-cache-pv.yaml" "$fs_id" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding="utf-8")
token = "__EFS_FILE_SYSTEM_ID__"
if source.count(token) != 1: raise SystemExit(f"expected one {token} token")
Path(sys.argv[2]).write_text(source.replace(token, sys.argv[3]), encoding="utf-8")
PY

approve_run "Prometheus and Grafana in namespace monitoring" \
  "part of the active cluster baseline" "Restore observability" \
  "Installs Kubernetes monitoring resources" "Deleted with the cluster" \
  helm upgrade -i monitoring prometheus-community/kube-prometheus-stack \
    --repo https://prometheus-community.github.io/helm-charts --namespace monitoring --create-namespace --wait

approve_run "KEDA in namespace keda" "part of the active cluster baseline" \
  "Restore inference autoscaling" "Installs Kubernetes autoscaling resources" \
  "Deleted with the cluster" \
  helm upgrade -i keda kedacore/keda --repo https://kedacore.github.io/charts \
    --namespace keda --create-namespace --wait

approve_run "EFS cache, vLLM, service, metrics, and autoscaling objects" \
  '$0 GPU compute until a GPU group is separately scaled above zero' \
  "Restore the experiment workload" "Creates Kubernetes objects; vLLM stays Pending" \
  "Deleted with the cluster" \
  kubectl apply -f "$temp_dir/hf-cache-pv.yaml" -f "$SCRIPT_DIR/vllm-deployment.yaml" \
    -f "$SCRIPT_DIR/vllm-service.yaml" -f "$SCRIPT_DIR/vllm-servicemonitor.yaml" \
    -f "$SCRIPT_DIR/vllm-scaledobject.yaml"

kubectl -n monitoring create configmap vllm-dashboard \
  --from-file="$SCRIPT_DIR/grafana-vllm-dashboard.json" --dry-run=client -o yaml > "$temp_dir/dashboard.yaml"
approve_run "Grafana dashboard ConfigMap" '$0 beyond the cluster baseline' \
  "Restore the versioned dashboard" "Creates one Kubernetes ConfigMap" \
  "Deleted with the cluster" kubectl apply -f "$temp_dir/dashboard.yaml"
approve_run "Grafana dashboard discovery label" '$0' "Make Grafana load the dashboard" \
  "Labels one ConfigMap" "Deleted with the cluster" \
  kubectl -n monitoring label configmap vllm-dashboard grafana_dashboard=1 --overwrite

for nodegroup in gpu-spot gpu-od; do
  desired=$(aws eks describe-nodegroup --profile "$PROFILE" --region "$REGION" \
    --cluster-name "$CLUSTER" --nodegroup-name "$nodegroup" \
    --query 'nodegroup.scalingConfig.desiredSize' --output text)
  [[ $desired == 0 ]] || { echo "unsafe result: $nodegroup desired size is $desired" >&2; exit 1; }
done
echo "rebuild complete: GPU node groups are parked at zero"
echo "run $SCRIPT_DIR/teardown-cluster.sh --plan before leaving the session"
