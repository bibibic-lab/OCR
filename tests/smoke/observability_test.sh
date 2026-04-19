#!/usr/bin/env bash
set -euo pipefail

command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not found"; exit 2; }

# Grafana deploy
kubectl -n observability wait --for=condition=Available deploy -l app.kubernetes.io/name=grafana --timeout=120s

# Prometheus: Operator-stamped label is app.kubernetes.io/name=prometheus (not "app=prometheus")
kubectl -n observability wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus --timeout=120s

# Prometheus svc: kps chart uses legacy 'app=kube-prometheus-stack-prometheus' label
# on the Service (not app.kubernetes.io/name=prometheus which is on pods).
# Verify service exists before port-forward (svc name can vary by chart version)
PROM_SVC=$(kubectl -n observability get svc -l app=kube-prometheus-stack-prometheus \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "$PROM_SVC" ] || { echo "FAIL: prometheus service not found"; exit 1; }

# port-forward with trap-based cleanup (no race, no leak)
trap 'kill $PF 2>/dev/null || true' EXIT
kubectl -n observability port-forward "svc/$PROM_SVC" 9090:9090 >/tmp/prom-pf.log 2>&1 &
PF=$!
for _ in $(seq 1 30); do grep -q "Forwarding from" /tmp/prom-pf.log && break; sleep 1; done

curl -sf http://localhost:9090/-/ready >/dev/null || { echo "FAIL: prometheus not ready"; exit 1; }

# OpenSearch cluster health (no TTY in CI: drop -it)
# dev는 security plugin disabled → http + no auth. Phase 1에 auth 복구.
OPENSEARCH_POD=$(kubectl -n observability get pod -l app.kubernetes.io/name=opensearch -o jsonpath='{.items[0].metadata.name}')
STATUS=$(kubectl -n observability exec "$OPENSEARCH_POD" -- \
  curl -s http://localhost:9200/_cluster/health \
  | jq -r .status)

case "$STATUS" in
  green|yellow) ;;
  *) echo "FAIL: opensearch cluster status=$STATUS"; exit 1 ;;
esac

echo "OK: prometheus + opensearch healthy"
