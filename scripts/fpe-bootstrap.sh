#!/usr/bin/env bash
# =============================================================================
# fpe-bootstrap.sh
# FPE Tokenization Service용 OpenBao KV 키 및 정책/롤 초기화
#
# 수행 작업:
#   1. OpenBao KV v2에 FPE 키 등록 (rrn / card / account / passport)
#      경로: kv/security/fpe-keys/{type}
#      키: aes_key_hex (64자 hex, 256-bit), tweak_hex (14자 hex, 56-bit), kek_version
#   2. FPE 서비스용 pg-pii DSN KV 등록
#      경로: kv/security/fpe-service
#   3. ESO 정책 확장: kv/data/security/* read 추가
#   4. fpe-service Kubernetes auth 롤 등록
#   5. 개발용 static BAO_TOKEN Secret 생성 (Optional)
#
# 사용법:
#   bash scripts/fpe-bootstrap.sh
#   bash scripts/fpe-bootstrap.sh --force    # 기존 키도 강제 덮어쓰기
#
# 사전 조건:
#   - openbao-0 파드 Running (security ns)
#   - openbao-init-keys Secret 존재
#   - kubectl 컨텍스트 = OCR 클러스터
#
# =============================================================================
set -euo pipefail

OPENBAO_NS="security"
OPENBAO_POD="openbao-0"
BAO_ADDR="https://127.0.0.1:8200"
FORCE_OVERWRITE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE_OVERWRITE=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
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
  error "root token 획득 실패. openbao-init-keys Secret 확인 필요."
  exit 1
fi
success "root token 확인"

# ─── bao 실행 래퍼 ────────────────────────────────────────────────────────
bao_exec() {
  kubectl -n "$OPENBAO_NS" exec "$OPENBAO_POD" -- \
    env BAO_ADDR="$BAO_ADDR" BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
    bao "$@"
}

# ─── 1. KV v2 활성화 확인 ────────────────────────────────────────────────
info "KV v2 상태 확인..."
KV_ENABLED=$(bao_exec secrets list -format=json 2>/dev/null | jq -r '.["kv/"] // empty' || true)
if [[ -z "$KV_ENABLED" ]]; then
  info "KV v2 활성화..."
  bao_exec secrets enable -path="kv" -version=2 kv
  success "KV v2 활성화 완료"
else
  success "KV v2 이미 활성화됨"
fi

# ─── 2. FPE 키 등록 ───────────────────────────────────────────────────────
FIELD_TYPES=("rrn" "card" "account" "passport")

for ftype in "${FIELD_TYPES[@]}"; do
  KV_PATH="kv/security/fpe-keys/${ftype}"
  info "FPE 키 확인: ${KV_PATH}..."

  EXISTING=$(bao_exec kv get -format=json "$KV_PATH" 2>/dev/null \
    | jq -r '.data.data.aes_key_hex // empty' || true)

  if [[ -n "$EXISTING" ]] && [[ "$FORCE_OVERWRITE" == "false" ]]; then
    success "FPE 키 이미 존재 (${ftype}) — 스킵. 갱신하려면 --force 사용"
  else
    if [[ -n "$EXISTING" ]]; then
      warn "기존 FPE 키 덮어쓰기 (--force): ${ftype}"
    fi
    # FF3-1 요건: 256-bit AES key (32 bytes = 64 hex), 56-bit tweak (7 bytes = 14 hex)
    AES_KEY=$(openssl rand -hex 32)
    TWEAK=$(openssl rand -hex 7)
    bao_exec kv put "$KV_PATH" \
      aes_key_hex="$AES_KEY" \
      tweak_hex="$TWEAK" \
      kek_version="v1"
    success "FPE 키 등록 완료: ${ftype} (kek_version=v1)"
  fi
done

# ─── 3. fpe-service 설정 KV 등록 ────────────────────────────────────────
info "fpe-service 설정 KV 등록..."
FPE_SERVICE_PATH="kv/security/fpe-service"
EXISTING_DSN=$(bao_exec kv get -format=json "$FPE_SERVICE_PATH" 2>/dev/null \
  | jq -r '.data.data.pii_db_dsn // empty' || true)

if [[ -n "$EXISTING_DSN" ]] && [[ "$FORCE_OVERWRITE" == "false" ]]; then
  success "fpe-service 설정 이미 존재 — 스킵"
else
  # dev 기본값: pg-pii CNPG primary에 fpe_user
  bao_exec kv put "$FPE_SERVICE_PATH" \
    pii_db_dsn="postgresql://fpe_user:fpe_dev_pass_change_in_production@pg-pii-rw.security.svc.cluster.local:5432/app" \
    pii_db_password="fpe_dev_pass_change_in_production"
  warn "pg-pii DSN에 dev 패스워드 사용 중. production 전 반드시 변경 필요."
  success "fpe-service 설정 KV 등록 완료"
fi

# ─── 4. ESO 정책 확장 (security/* read) ─────────────────────────────────
info "ESO 정책 확장: kv/data/security/* read 추가..."
POLICY_HCL='
path "kv/data/admin/*" { capabilities = ["read"] }
path "kv/metadata/admin/*" { capabilities = ["read", "list"] }
path "kv/data/security/*" { capabilities = ["read"] }
path "kv/metadata/security/*" { capabilities = ["read", "list"] }
'
bao_exec write "sys/policies/acl/eso-admin-reader" policy="$POLICY_HCL"
success "eso-admin-reader 정책 업데이트 완료"

# ─── 5. fpe-service Kubernetes auth 롤 등록 ──────────────────────────────
info "fpe-service Kubernetes auth 롤 등록..."

# fpe-service 전용 정책 생성
FPE_POLICY_HCL='
path "kv/data/security/fpe-keys/*" { capabilities = ["read"] }
path "kv/metadata/security/fpe-keys/*" { capabilities = ["read", "list"] }
path "kv/data/security/fpe-service" { capabilities = ["read"] }
'
bao_exec write "sys/policies/acl/fpe-service-reader" policy="$FPE_POLICY_HCL"
success "fpe-service-reader 정책 생성 완료"

# Kubernetes 롤 생성 (fpe-service SA, security ns)
bao_exec write "auth/kubernetes/role/fpe-service" \
  bound_service_account_names="fpe-service" \
  bound_service_account_namespaces="security" \
  policies="fpe-service-reader" \
  ttl="1h"
success "fpe-service Kubernetes auth 롤 등록 완료"

# ─── 6. 개발용 static token Secret 생성 ─────────────────────────────────
info "개발용 static token 생성..."
STATIC_TOKEN=$(bao_exec token create -format=json \
  -policy="fpe-service-reader" \
  -ttl="87600h" \
  -display-name="fpe-service-dev" 2>/dev/null | jq -r '.auth.client_token' || true)

if [[ -n "$STATIC_TOKEN" ]] && [[ "$STATIC_TOKEN" != "null" ]]; then
  # k8s Secret으로 저장 (개발 편의용 — production에서는 K8s auth 사용)
  kubectl -n security create secret generic fpe-service-bao-token \
    --from-literal=token="$STATIC_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  success "fpe-service-bao-token Secret 생성 완료 (TTL: 10년, dev only)"
else
  warn "static token 생성 실패 — K8s auth 폴백 사용"
fi

# ─── 최종 요약 ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo " FPE Bootstrap 완료"
echo "════════════════════════════════════════════════════════════════"
echo " FPE 키 경로:"
for ftype in "${FIELD_TYPES[@]}"; do
  echo "   kv/security/fpe-keys/${ftype}"
done
echo ""
echo " 다음 단계:"
echo "   1. kubectl apply -f infra/manifests/fpe-service/pg-pii-fpe-schema.yaml"
echo "   2. kubectl apply -f infra/manifests/fpe-service/"
echo "   3. bash tests/smoke/fpe_smoke.sh"
echo "════════════════════════════════════════════════════════════════"
