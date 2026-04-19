#!/usr/bin/env bash
set -euo pipefail

# Postgres smoke: functional psql check on both clusters.
# NOTE: CNPG operator cross-ns status reconcile(port 8000) currently shows
# "Instance Status Extraction Error: HTTP communication issue" for pg-main
# due to Cilium policy identity mapping quirk. Postgres itself is fully
# operational (psql from within the pod works). Phase 1에 Cilium CCNP를
# fromEntities=cluster + identity label indexing 문제를 정밀 해결 예정.
command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not found"; exit 2; }

# pg-main: at least 1 instance Ready + psql returns expected row
pg_main_ready=$(kubectl -n processing get cluster pg-main -o jsonpath='{.status.readyInstances}')
[ "$pg_main_ready" -ge 1 ] || { echo "FAIL: pg-main readyInstances=$pg_main_ready"; exit 1; }

kubectl -n processing exec pg-main-1 -c postgres -- psql -U postgres -d ocr \
  -tAc "SELECT 1" 2>/dev/null | grep -q '^1$' \
  || { echo "FAIL: pg-main psql query failed"; exit 1; }

# pg-pii: same checks
pg_pii_ready=$(kubectl -n security get cluster pg-pii -o jsonpath='{.status.readyInstances}')
[ "$pg_pii_ready" -ge 1 ] || { echo "FAIL: pg-pii readyInstances=$pg_pii_ready"; exit 1; }

kubectl -n security exec pg-pii-1 -c postgres -- psql -U postgres -d pii_vault \
  -tAc "SELECT 1" 2>/dev/null | grep -q '^1$' \
  || { echo "FAIL: pg-pii psql query failed"; exit 1; }

echo "OK: pg-main + pg-pii functional (psql roundtrip passes)"
