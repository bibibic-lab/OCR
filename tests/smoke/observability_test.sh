#!/usr/bin/env bash
set -euo pipefail

command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not found"; exit 2; }

kubectl -n observability wait --for=condition=Available deploy -l app.kubernetes.io/name=grafana --timeout=120s
kubectl -n observability wait --for=condition=Ready pod -l app=prometheus --timeout=120s

# Prometheus 타겟 hit 확인
kubectl -n observability port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
PF=$!
sleep 3
curl -sf localhost:9090/-/ready || { kill $PF; echo "FAIL: prometheus not ready"; exit 1; }
kill $PF

# OpenSearch cluster health
kubectl -n observability exec -it opensearch-cluster-master-0 -- \
  curl -sk -u admin:"$(kubectl -n observability get secret opensearch-admin -o jsonpath='{.data.password}' | base64 -d)" \
  https://localhost:9200/_cluster/health | jq -r .status | grep -E 'green|yellow' \
  || { echo "FAIL: opensearch red"; exit 1; }

echo "OK: prometheus + opensearch healthy"
