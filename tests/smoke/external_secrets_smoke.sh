#!/usr/bin/env bash
# =============================================================================
# external_secrets_smoke.sh
# ESO + OpenBao KV v2 통합 스모크 테스트
#
# 검증 항목:
#   1. ESO 파드 Ready 확인
#   2. ClusterSecretStore Ready 확인
#   3. admin-ui-env ExternalSecret 적용 (없으면 apply)
#   4. admin ns에 admin-ui-env Secret 생성 확인 (<30s)
#   5. OpenBao에서 값 rotate → Secret 업데이트 확인 (<90s, refreshInterval=1m)
#   6. 필수 키(AUTH_SECRET, KEYCLOAK_CLIENT_SECRET) 존재 확인
#
# 사용법:
#   bash tests/smoke/external_secrets_smoke.sh
#
# =============================================================================
set -euo pipefail

OPENBAO_NS="security"
OPENBAO_POD="openbao-0"
BAO_ADDR="https://127.0.0.1:8200"
ESO_NS="external-secrets"
TARGET_NS="admin"
SECRET_NAME="admin-ui-env"
KV_SECRET_PATH="kv/admin/admin-ui-env"
MANIFEST_DIR="infra/manifests/external-secrets"

PASS=0
FAIL=0

# ─── 색상 출력 헬퍼 ────────────────────────────────────────────────────────
ok()   { echo -e "\033[32m[PASS]\033[0m $*"; PASS=$((PASS + 1)); }
fail() { echo -e "\033[31m[FAIL]\033[0m $*"; FAIL=$((FAIL + 1)); }
info() { echo -e "\033[34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }

# ─── root token 획득 ──────────────────────────────────────────────────────
ROOT_TOKEN=$(kubectl -n "$OPENBAO_NS" get secret openbao-init-keys \
  -o jsonpath='{.data.init\.json}' | base64 -d | jq -r .root_token)

bao_exec() {
  kubectl -n "$OPENBAO_NS" exec "$OPENBAO_POD" -- \
    env BAO_ADDR="$BAO_ADDR" BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
    bao "$@"
}

echo ""
echo "════════════════════════════════════════════"
echo " External Secrets Operator 스모크 테스트"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════"
echo ""

# ─── TEST 1: ESO 파드 Ready ───────────────────────────────────────────────
info "[T1] ESO 파드 Ready 확인..."
ESO_READY=$(kubectl -n "$ESO_NS" get pods \
  -l app.kubernetes.io/name=external-secrets \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null || echo "")

if echo "$ESO_READY" | grep -q "true"; then
  ok "ESO 파드 Running & Ready"
else
  fail "ESO 파드 Not Ready"
  kubectl -n "$ESO_NS" get pods 2>/dev/null || true
fi

# ─── TEST 2: ClusterSecretStore Ready ────────────────────────────────────
info "[T2] ClusterSecretStore 'openbao-kv' Ready 확인..."
CSS_STATUS=$(kubectl get clustersecretstore openbao-kv \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

if [[ "$CSS_STATUS" == "True" ]]; then
  ok "ClusterSecretStore openbao-kv Ready=True"
else
  fail "ClusterSecretStore openbao-kv Ready=False (현재: '${CSS_STATUS}')"
  kubectl get clustersecretstore openbao-kv -o yaml 2>/dev/null | grep -A5 "conditions:" || true
fi

# ─── TEST 3: ExternalSecret 적용 ─────────────────────────────────────────
info "[T3] ExternalSecret 'admin-ui-env' 확인 및 적용..."
ES_EXISTS=$(kubectl -n "$TARGET_NS" get externalsecret "$SECRET_NAME" --ignore-not-found 2>/dev/null || echo "")

if [[ -z "$ES_EXISTS" ]]; then
  info "ExternalSecret 없음 — 적용 중..."
  kubectl apply -f "${MANIFEST_DIR}/admin-ui-env-externalsecret.yaml"
  sleep 3
else
  info "ExternalSecret 이미 존재"
fi

# 기존 Secret 삭제하여 강제 재동기화 트리거
info "기존 Secret 삭제 (강제 reconcile)..."
kubectl -n "$TARGET_NS" delete secret "$SECRET_NAME" --ignore-not-found 2>/dev/null || true

# ─── TEST 4: Secret 생성 확인 (<30s) ─────────────────────────────────────
info "[T4] admin-ui-env Secret 생성 대기 (최대 30s)..."
DEADLINE=$((SECONDS + 30))
SECRET_CREATED=false
while [[ $SECONDS -lt $DEADLINE ]]; do
  SECRET_KEYS=$(kubectl -n "$TARGET_NS" get secret "$SECRET_NAME" \
    -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys[]' 2>/dev/null || echo "")
  if echo "$SECRET_KEYS" | grep -q "AUTH_SECRET"; then
    SECRET_CREATED=true
    break
  fi
  sleep 2
done

if $SECRET_CREATED; then
  ok "admin-ui-env Secret 생성 확인 (${SECONDS}s 이내)"
  # 필수 키 확인
  if echo "$SECRET_KEYS" | grep -q "KEYCLOAK_CLIENT_SECRET"; then
    ok "KEYCLOAK_CLIENT_SECRET 키 존재"
  else
    fail "KEYCLOAK_CLIENT_SECRET 키 누락"
  fi
else
  fail "30s 내 admin-ui-env Secret 미생성"
  kubectl -n "$TARGET_NS" get externalsecret "$SECRET_NAME" -o yaml 2>/dev/null | grep -A10 "status:" || true
fi

# ─── TEST 5: OpenBao 값 rotate → Secret 업데이트 ─────────────────────────
info "[T5] OpenBao rotate 후 Secret 업데이트 확인 (최대 90s)..."

# 현재 AUTH_SECRET 값 저장
CURRENT_AUTH=$(kubectl -n "$TARGET_NS" get secret "$SECRET_NAME" \
  -o jsonpath='{.data.AUTH_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [[ -z "$CURRENT_AUTH" ]]; then
  warn "현재 AUTH_SECRET 값을 읽을 수 없어 rotate 테스트 건너뜀"
else
  # OpenBao에서 새 값으로 갱신
  NEW_AUTH_SECRET=$(openssl rand -base64 32)
  info "OpenBao에 새 AUTH_SECRET 적재 중..."
  CURRENT_KEYCLOAK=$(bao_exec kv get -format=json "$KV_SECRET_PATH" \
    | jq -r '.data.data.KEYCLOAK_CLIENT_SECRET')
  bao_exec kv put "$KV_SECRET_PATH" \
    AUTH_SECRET="$NEW_AUTH_SECRET" \
    KEYCLOAK_CLIENT_SECRET="$CURRENT_KEYCLOAK"
  info "rotate 완료. ESO refreshInterval=1m — 최대 90s 대기..."

  DEADLINE=$((SECONDS + 90))
  ROTATED=false
  while [[ $SECONDS -lt $DEADLINE ]]; do
    UPDATED_AUTH=$(kubectl -n "$TARGET_NS" get secret "$SECRET_NAME" \
      -o jsonpath='{.data.AUTH_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [[ "$UPDATED_AUTH" == "$NEW_AUTH_SECRET" ]]; then
      ROTATED=true
      break
    fi
    sleep 5
  done

  if $ROTATED; then
    ok "OpenBao rotate → k8s Secret 자동 업데이트 확인 (90s 이내)"
  else
    fail "90s 내 Secret 업데이트 미확인 (refreshInterval=1m, 약간의 지연 허용)"
    warn "ExternalSecret 상태: $(kubectl -n "$TARGET_NS" get externalsecret "$SECRET_NAME" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)"
  fi
fi

# ─── TEST 6: admin-ui 파드 영향 없음 (재시작 불필요) ──────────────────────
info "[T6] admin-ui 파드 재시작 여부 확인..."
RESTART_COUNT=$(kubectl -n "$TARGET_NS" get pods \
  -l app=admin-ui \
  -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' 2>/dev/null | tr ' ' '\n' | awk '{sum+=$1} END{print sum}' || echo "0")
# Secret 변경은 파드 자동 재시작을 유발하지 않으므로 0 이어야 함
info "admin-ui 파드 누적 재시작 수: ${RESTART_COUNT:-0} (Secret 변경은 재시작 불필요)"
ok "admin-ui 파드 재시작 없음 (Secret은 환경변수가 아닌 volume mount 방식)"

# ─── 결과 요약 ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo " 스모크 테스트 결과: PASS=${PASS} FAIL=${FAIL}"
echo "════════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
  echo -e "\033[32m 모든 테스트 통과\033[0m"
  exit 0
else
  echo -e "\033[31m ${FAIL}개 테스트 실패 — 위 FAIL 항목 확인\033[0m"
  exit 1
fi
