#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p results
kubectl create configmap k6-script --from-file=k6-load.js --dry-run=client -o yaml | kubectl apply -f -
for VUS in 8 16 32 64; do
  echo "=== ${VUS} VUs ==="
  date -u +"%Y-%m-%dT%H:%M:%SZ start ${VUS}" >> results/sweep-timestamps.txt
  sed "s/__VUS__/${VUS}/" k6-job.yaml | kubectl apply -f -
  kubectl wait --for=condition=complete job/k6-knee --timeout=15m
  kubectl logs job/k6-knee > "results/knee-${VUS}vus.txt"
  kubectl delete job k6-knee
  date -u +"%Y-%m-%dT%H:%M:%SZ end ${VUS}" >> results/sweep-timestamps.txt
  sleep 60
done
echo "Sweep done. Summaries in results/"
