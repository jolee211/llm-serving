#!/usr/bin/env bash
# Full rebuild from nothing: ~35 min. Companion teardown:
#   eksctl delete cluster --name llm-serving --region us-east-1 --profile personal --wait
set -euo pipefail
cd "$(dirname "$0")"
PROFILE="${AWS_PROFILE_OVERRIDE:-personal}"

echo "=== 1/5 cluster (control plane + CPU nodes, ~20 min)"
eksctl create cluster -f cluster.yaml --profile "$PROFILE"

echo "=== 2/5 GPU nodegroups (spot primary, on-demand fallback; both parked at 0 after create)"
eksctl create nodegroup --config-file gpu-nodegroup.yaml --profile "$PROFILE" || echo "WARN: spot nodegroup create failed (capacity?); check ASG activities, continue"
eksctl scale nodegroup --cluster llm-serving --name gpu-spot --nodes 0 --profile "$PROFILE" --region us-east-1 || true

echo "=== 3/5 monitoring stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
helm upgrade -i monitoring prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace --wait

echo "=== 4/5 vLLM + scrape wiring + dashboard"
kubectl apply -f vllm-deployment.yaml -f vllm-service.yaml -f vllm-servicemonitor.yaml
kubectl -n monitoring create configmap vllm-dashboard --from-file=grafana-vllm-dashboard.json --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring label configmap vllm-dashboard grafana_dashboard=1 --overwrite

echo "=== 5/5 done. GPU is parked; to serve:"
echo "  eksctl scale nodegroup --cluster llm-serving --name gpu-spot --nodes 1 --profile $PROFILE --region us-east-1"
echo "  (fallback: eksctl create nodegroup --config-file gpu-od-nodegroup.yaml --profile $PROFILE)"
echo "  kubectl wait --for=condition=Ready pod -l app=vllm-qwen --timeout=25m   # ~10 min cold start"
