#!/usr/bin/env bash
set -euo pipefail

# P0 Integration Smoke — 전체 플랫폼 readiness 통합 검증
# 모든 개별 smoke test를 순차 실행 + 최종 cross-component 검증
command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not found"; exit 2; }
cd "$(dirname "$0")/../.."

pass() { echo "  [✓] $1"; }
fail() { echo "  [✗] $1"; exit 1; }

echo "══════ P0 Integration Smoke ══════"

# T3 — 5 네임스페이스
bash tests/smoke/namespaces_test.sh >/dev/null && pass "T3 5 namespaces with labels" || fail "T3 namespaces"

# T4 — NetworkPolicy (Cilium + default-deny + cross-zone block)
bash tests/smoke/network_policies_test.sh >/dev/null && pass "T4 NetworkPolicy zero-trust" || fail "T4 network policies"

# T5 — cert-manager Root CA + 테스트 인증서 발급
bash tests/smoke/cert_manager_test.sh >/dev/null && pass "T5 cert-manager + Root CA" || fail "T5 cert-manager"

# T6 — Prometheus + Grafana + OpenSearch
bash tests/smoke/observability_test.sh >/dev/null && pass "T6 Prometheus + Grafana + OpenSearch" || fail "T6 observability"

# T7 — Postgres pg-main + pg-pii psql roundtrip
bash tests/smoke/postgres_test.sh >/dev/null && pass "T7 pg-main + pg-pii functional" || fail "T7 postgres"

# T8 — SeaweedFS master/volume/filer health
bash tests/smoke/seaweedfs_test.sh >/dev/null && pass "T8 SeaweedFS master/volume/filer" || fail "T8 seaweedfs"

# T9 — OpenBao Transit KEK encrypt/decrypt
bash tests/smoke/openbao_transit_test.sh >/dev/null && pass "T9 OpenBao Transit KEK roundtrip" || fail "T9 openbao"

# T10 — Keycloak OIDC token 발급 + introspect
bash tests/smoke/keycloak_token_test.sh >/dev/null && pass "T10 Keycloak ocr realm + OIDC" || fail "T10 keycloak"

# T11 — ArgoCD Ready + CRDs + umbrella chart render
bash tests/smoke/argocd_test.sh >/dev/null && pass "T11 ArgoCD + umbrella chart" || fail "T11 argocd"

echo ""
echo "══════ Cross-component integrity ══════"

# helm releases 8개 모두 deployed
deployed=$(helm list -A --no-headers 2>/dev/null | awk '$8=="deployed"{c++} END{print c+0}')
[ "$deployed" -ge 8 ] && pass "helm releases ≥ 8 deployed ($deployed)" || fail "helm releases (got $deployed)"

# 핵심 CRD 그룹 존재
for g in cert-manager.io postgresql.cnpg.io argoproj.io cilium.io; do
  kubectl api-resources --api-group="$g" --no-headers 2>/dev/null | head -1 | grep -q . \
    && pass "CRD group $g" || fail "CRD group $g missing"
done

# Root CA가 ClusterIssuer로 서명 가능
kubectl get clusterissuer ocr-internal -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
  | grep -q True && pass "ClusterIssuer ocr-internal Ready" || fail "ClusterIssuer"

# OpenBao Transit KEK 3개 모두 존재
ROOT=$(kubectl -n security get secret openbao-init-keys -o jsonpath='{.data.init\.json}' | base64 -d | jq -r .root_token)
for kek in upload-kek storage-kek egress-kek; do
  result=$(kubectl -n security exec openbao-0 -- env \
    BAO_ADDR=https://127.0.0.1:8200 \
    BAO_SKIP_VERIFY=true \
    BAO_TOKEN="$ROOT" \
    bao read -format=json "transit/keys/$kek" 2>/dev/null \
    | jq -r ".data.name // \"missing\"")
  [ "$result" = "$kek" ] && pass "OpenBao KEK: $kek" || fail "OpenBao KEK $kek (got '$result')"
done

echo ""
echo "══════ P0 PLATFORM READY ══════"
