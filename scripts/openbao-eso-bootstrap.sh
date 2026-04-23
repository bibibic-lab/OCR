#!/usr/bin/env bash
# =============================================================================
# openbao-eso-bootstrap.sh
# OpenBao: KV v2 + Kubernetes auth + ESO 정책·롤·테스트 데이터 멱등 설정
#
# 실행 전 요건:
#   - kubectl 컨텍스트가 OCR 클러스터를 가리킬 것
#   - openbao-0 파드 Running 상태
#   - openbao-init-keys Secret 존재 (security ns)
#   - ESO 설치 완료 (external-secrets ns)
#
# 사용법:
#   bash scripts/openbao-eso-bootstrap.sh
#   bash scripts/openbao-eso-bootstrap.sh --keycloak-secret "실제시크릿값"
#
# =============================================================================
set -euo pipefail

OPENBAO_NS="security"
OPENBAO_POD="openbao-0"
BAO_ADDR="https://127.0.0.1:8200"
ESO_SA_NAME="external-secrets"
ESO_SA_NS="external-secrets"
KV_PATH="kv"
POLICY_NAME="eso-admin-reader"
ROLE_NAME="eso-admin-reader"
KV_SECRET_PATH="kv/admin/admin-ui-env"

# 선택적 인수
KEYCLOAK_SECRET_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --keycloak-secret)
      KEYCLOAK_SECRET_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ─── 색상 출력 헬퍼 ────────────────────────────────────────────────────────
info()    { echo -e "\033[34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[33m[WARN]\033[0m  $*"; }
error()   { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

# ─── root token 획득 ──────────────────────────────────────────────────────
info "root token 획득 중..."
ROOT_TOKEN=$(kubectl -n "$OPENBAO_NS" get secret openbao-init-keys \
  -o jsonpath='{.data.init\.json}' | base64 -d | jq -r .root_token)

if [[ -z "$ROOT_TOKEN" || "$ROOT_TOKEN" == "null" ]]; then
  error "root token을 가져올 수 없습니다. openbao-init-keys Secret 확인 필요."
  exit 1
fi
success "root token 확인 (길이: ${#ROOT_TOKEN})"

# ─── bao 실행 래퍼 ────────────────────────────────────────────────────────
bao_exec() {
  kubectl -n "$OPENBAO_NS" exec "$OPENBAO_POD" -- \
    env BAO_ADDR="$BAO_ADDR" BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
    bao "$@"
}

# ─── 1. KV v2 활성화 ─────────────────────────────────────────────────────
info "KV v2 엔진 상태 확인..."
KV_ENABLED=$(bao_exec secrets list -format=json 2>/dev/null | jq -r ".[\"${KV_PATH}/\"] // empty" || true)
if [[ -n "$KV_ENABLED" ]]; then
  success "KV v2 이미 활성화됨 (path: ${KV_PATH}/)"
else
  info "KV v2 활성화 중..."
  bao_exec secrets enable -path="$KV_PATH" -version=2 kv
  success "KV v2 활성화 완료"
fi

# ─── 2. Kubernetes auth 활성화 ───────────────────────────────────────────
info "Kubernetes auth 상태 확인..."
K8S_AUTH_ENABLED=$(bao_exec auth list -format=json 2>/dev/null | jq -r '.["kubernetes/"] // empty' || true)
if [[ -n "$K8S_AUTH_ENABLED" ]]; then
  success "Kubernetes auth 이미 활성화됨"
else
  info "Kubernetes auth 활성화 중..."
  bao_exec auth enable kubernetes
  success "Kubernetes auth 활성화 완료"
fi

# ─── 3. Kubernetes auth 구성 ─────────────────────────────────────────────
info "Kubernetes auth 구성 적용 중..."
bao_exec write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
success "Kubernetes auth 구성 완료"

# ─── 4. ESO 정책 생성/갱신 ───────────────────────────────────────────────
# 주의: kubectl exec 환경에서는 `bao policy write NAME -` (stdin)이 동작하지 않음.
# (stdin이 파드 exec 채널을 통해 전달되지 않음)
# 대신 sys/policies/acl/ REST 엔드포인트를 직접 사용.
info "ESO 정책 '${POLICY_NAME}' 생성 중..."
POLICY_HCL='path "kv/data/admin/*" { capabilities = ["read"] } path "kv/metadata/admin/*" { capabilities = ["read", "list"] }'
bao_exec write "sys/policies/acl/${POLICY_NAME}" policy="$POLICY_HCL"
success "정책 '${POLICY_NAME}' 적용 완료"

# ─── 5. Kubernetes 롤 생성/갱신 ──────────────────────────────────────────
info "Kubernetes 롤 '${ROLE_NAME}' 생성 중..."
bao_exec write "auth/kubernetes/role/${ROLE_NAME}" \
  bound_service_account_names="$ESO_SA_NAME" \
  bound_service_account_namespaces="$ESO_SA_NS" \
  policies="$POLICY_NAME" \
  ttl="1h"
success "롤 '${ROLE_NAME}' 적용 완료"

# ─── 6. 테스트 시크릿 적재 ───────────────────────────────────────────────
info "kv/admin/admin-ui-env 초기 데이터 확인..."
EXISTING=$(bao_exec kv get -format=json "$KV_SECRET_PATH" 2>/dev/null | jq -r '.data.data.AUTH_SECRET // empty' || true)

if [[ -n "$EXISTING" ]]; then
  success "kv/admin/admin-ui-env 이미 존재 — 덮어쓰지 않음"
  warn "값을 갱신하려면: bao kv put ${KV_SECRET_PATH} AUTH_SECRET=새값 KEYCLOAK_CLIENT_SECRET=새값"
else
  info "kv/admin/admin-ui-env 초기 데이터 적재..."
  AUTH_SECRET=$(openssl rand -base64 32)

  if [[ -n "$KEYCLOAK_SECRET_OVERRIDE" ]]; then
    KEYCLOAK_CLIENT_SECRET="$KEYCLOAK_SECRET_OVERRIDE"
  else
    # placeholder — 실제 Keycloak 클라이언트 시크릿으로 교체 필요
    KEYCLOAK_CLIENT_SECRET="PLACEHOLDER-replace-with-actual-keycloak-client-secret"
    warn "KEYCLOAK_CLIENT_SECRET 은 placeholder. --keycloak-secret 인수로 실제 값 제공 권장."
  fi

  bao_exec kv put "$KV_SECRET_PATH" \
    AUTH_SECRET="$AUTH_SECRET" \
    KEYCLOAK_CLIENT_SECRET="$KEYCLOAK_CLIENT_SECRET"
  success "kv/admin/admin-ui-env 초기 데이터 적재 완료"
fi

# ─── 최종 상태 요약 ───────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo " OpenBao ESO Bootstrap 완료"
echo "════════════════════════════════════════════"
bao_exec secrets list 2>/dev/null | grep -E "^(Path|kv|---)"
echo ""
bao_exec auth list 2>/dev/null | grep -E "^(Path|kubernetes|token|---)"
echo ""
success "다음 단계: ESO ClusterSecretStore + ExternalSecret 적용"
echo "  kubectl apply -f infra/manifests/external-secrets/cluster-secret-store.yaml"
echo "  kubectl apply -f infra/manifests/external-secrets/admin-ui-env-externalsecret.yaml"
echo "  bash tests/smoke/external_secrets_smoke.sh"
