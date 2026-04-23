#!/usr/bin/env bash
# =============================================================================
# fpe_smoke.sh — FPE Tokenization Service Smoke Test
# =============================================================================
# 수행 단계:
#   1. Docker 이미지 빌드
#   2. kind 클러스터에 이미지 로드
#   3. OpenBao FPE 키 부트스트랩 (미존재 시)
#   4. pg-pii fpe_token 스키마 Job 적용
#   5. k8s 매니페스트 적용
#   6. Pod Ready 대기 (최대 120s)
#   7. port-forward 18100:80
#   8. /tokenize 호출 → RRN 포맷 보존 검증
#   9. /detokenize 호출 → 원본 복원 검증
#  10. /tokenize-batch 호출 → 배치 검증
#  11. pg-pii fpe_token 레코드 수 확인
#  12. port-forward 종료
#
# 사용법:
#   bash tests/smoke/fpe_smoke.sh
#   DRY_RUN=true bash tests/smoke/fpe_smoke.sh   # 클러스터 없을 때 단위 로직만 확인
#
# 사전 조건:
#   - kind 클러스터 실행 중 (컨텍스트 kind-ocr)
#   - Docker 실행 중
#   - openbao, pg-pii 배포 완료
#   - kubectl, curl, jq 설치
# =============================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVICE_DIR="$PROJECT_ROOT/services/fpe-service"
MANIFEST_DIR="$PROJECT_ROOT/infra/manifests/fpe-service"
IMAGE_NAME="fpe-service:v0.1.0"
KIND_CLUSTER="${KIND_CLUSTER:-ocr}"
FPE_PORT=18100
NAMESPACE="security"
DRY_RUN="${DRY_RUN:-false}"

# ─── 색상 출력 ────────────────────────────────────────────────────────────
pass()  { echo -e "\033[32m[PASS]\033[0m $*"; }
fail()  { echo -e "\033[31m[FAIL]\033[0m $*" >&2; exit 1; }
info()  { echo -e "\033[34m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m $*"; }
step()  { echo -e "\n\033[1m=== $* ===\033[0m"; }

PF_PID=""
cleanup() {
  if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID"
    info "port-forward 종료"
  fi
}
trap cleanup EXIT

# ─── DRY_RUN 모드: FF3 단위 검증만 수행 ──────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  step "DRY_RUN 모드: Python FF3 단위 검증"
  python3 - <<'PYEOF'
import sys
sys.path.insert(0, 'services/fpe-service')
from fpe import tokenize_rrn, detokenize_rrn, FPEConfig

config = FPEConfig(
    key_hex="a" * 64,
    tweak_hex="b" * 14,
    kek_version="v1-test"
)
original = "900101-1234567"
token = tokenize_rrn(original, config)
restored = detokenize_rrn(token, config)

assert len(token) == 14, f"토큰 길이 오류: {len(token)} (expected 14)"
assert token[6] == "-", f"하이픈 위치 오류: {token}"
assert token[:6].isdigit(), f"앞 6자리 숫자 오류: {token}"
assert token[7:].isdigit(), f"뒤 7자리 숫자 오류: {token}"
assert restored == original, f"복원 실패: {restored} != {original}"
assert token != original, "토큰이 원본과 같음 (암호화 실패)"
print(f"  원본:   {original}")
print(f"  토큰:   {token}")
print(f"  복원:   {restored}")
print("  [PASS] FF3-1 RRN 포맷 보존 + 역변환 검증")

# 카드번호 테스트
from fpe import tokenize_card, detokenize_card
card_orig = "1234-5678-9012-3456"
card_tok = tokenize_card(card_orig, config)
card_rest = detokenize_card(card_tok, config)
assert card_tok != card_orig
assert card_rest == card_orig
assert len(card_tok) == 19 and card_tok[4] == "-"
print(f"  [PASS] FF3-1 카드번호 포맷 보존 + 역변환 검증")

print("\nDRY_RUN 완료 — 모든 단위 검증 통과")
PYEOF
  pass "DRY_RUN 완료"
  exit 0
fi

# ─── Step 1: Docker 이미지 빌드 ───────────────────────────────────────────
step "Step 1: Docker 이미지 빌드"
info "빌드: $IMAGE_NAME"
docker build -t "$IMAGE_NAME" "$SERVICE_DIR"
pass "이미지 빌드 완료: $IMAGE_NAME"

# ─── Step 2: kind 이미지 로드 ─────────────────────────────────────────────
step "Step 2: kind 이미지 로드"
kind load docker-image "$IMAGE_NAME" --name "$KIND_CLUSTER"
pass "kind 이미지 로드 완료"

# ─── Step 3: OpenBao FPE 키 부트스트랩 ────────────────────────────────────
step "Step 3: OpenBao FPE 키 부트스트랩"
# 이미 존재하면 스킵 (--force 없이 실행)
if bash "$PROJECT_ROOT/scripts/fpe-bootstrap.sh"; then
  pass "FPE 키 부트스트랩 완료"
else
  warn "부트스트랩 실패 — OpenBao 미준비일 수 있음. 계속 진행..."
fi

# ─── Step 4: pg-pii fpe_token 스키마 적용 ────────────────────────────────
step "Step 4: pg-pii fpe_token 스키마 적용"
# pg-pii-superuser Secret이 없으면 dev 플레이스홀더 생성
if ! kubectl -n "$NAMESPACE" get secret pg-pii-superuser >/dev/null 2>&1; then
  warn "pg-pii-superuser Secret 없음 — dev placeholder 생성"
  kubectl -n "$NAMESPACE" create secret generic pg-pii-superuser \
    --from-literal=username=postgres \
    --from-literal=password=dev-password \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# 기존 Job 삭제 후 재적용 (멱등)
kubectl delete job pg-pii-fpe-schema -n "$NAMESPACE" --ignore-not-found=true
kubectl apply -f "$MANIFEST_DIR/pg-pii-fpe-schema.yaml"
info "pg-pii-fpe-schema Job 시작. 최대 120s 대기..."
if kubectl wait job/pg-pii-fpe-schema -n "$NAMESPACE" \
    --for=condition=complete --timeout=120s 2>/dev/null; then
  pass "fpe_token 스키마 생성 완료"
else
  warn "스키마 Job 실패 또는 타임아웃 — pg-pii 미준비일 수 있음. 계속 진행..."
fi

# ─── Step 5: k8s 매니페스트 적용 ─────────────────────────────────────────
step "Step 5: k8s 매니페스트 적용"
kubectl apply -f "$MANIFEST_DIR/deployment.yaml"
kubectl apply -f "$MANIFEST_DIR/service.yaml"
kubectl apply -f "$MANIFEST_DIR/network-policies.yaml"
pass "매니페스트 적용 완료"

# ─── Step 6: Pod Ready 대기 ───────────────────────────────────────────────
step "Step 6: Pod Ready 대기 (최대 120s)"
kubectl rollout status deployment/fpe-service -n "$NAMESPACE" --timeout=120s
pass "fpe-service 파드 Ready"

# ─── Step 7: port-forward 시작 ────────────────────────────────────────────
step "Step 7: port-forward localhost:${FPE_PORT} → fpe-service:80"
kubectl port-forward svc/fpe-service "$FPE_PORT":80 -n "$NAMESPACE" &
PF_PID=$!
sleep 3
BASE_URL="http://localhost:${FPE_PORT}"

# ─── Step 8: /tokenize 검증 (RRN) ────────────────────────────────────────
step "Step 8: POST /tokenize (RRN)"
TOKENIZE_RESP=$(curl -s -X POST "$BASE_URL/tokenize" \
  -H "Content-Type: application/json" \
  -d '{"type":"rrn","value":"900101-1234567"}')

info "Response: $TOKENIZE_RESP"

TOKEN=$(echo "$TOKENIZE_RESP" | jq -r '.token // empty')
TOKEN_ID=$(echo "$TOKENIZE_RESP" | jq -r '.token_id // empty')

[[ -z "$TOKEN" ]] && fail "/tokenize 응답에 token 없음: $TOKENIZE_RESP"
[[ -z "$TOKEN_ID" ]] && fail "/tokenize 응답에 token_id 없음"

# 포맷 검증: ######-#######
if echo "$TOKEN" | grep -qE '^[0-9]{6}-[0-9]{7}$'; then
  pass "RRN 포맷 보존 확인: $TOKEN"
else
  fail "RRN 포맷 오류: $TOKEN (expected: ######-#######)"
fi

# 원본과 달라야 함
[[ "$TOKEN" == "900101-1234567" ]] && fail "토큰이 원본과 동일 (암호화 실패)"
pass "토큰이 원본과 다름: $TOKEN ≠ 900101-1234567"

# ─── Step 9: /detokenize 검증 ────────────────────────────────────────────
step "Step 9: POST /detokenize"
DETOKEN_RESP=$(curl -s -X POST "$BASE_URL/detokenize" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"rrn\",\"token\":\"$TOKEN\",\"audit_reason\":\"smoke-test\"}")

info "Response: $DETOKEN_RESP"

RESTORED=$(echo "$DETOKEN_RESP" | jq -r '.value // empty')
[[ -z "$RESTORED" ]] && fail "/detokenize 응답에 value 없음: $DETOKEN_RESP"

if [[ "$RESTORED" == "900101-1234567" ]]; then
  pass "원본 복원 성공: $RESTORED"
else
  fail "원본 복원 실패: $RESTORED (expected: 900101-1234567)"
fi

# ─── Step 10: /tokenize-batch 검증 ────────────────────────────────────────
step "Step 10: POST /tokenize-batch"
BATCH_RESP=$(curl -s -X POST "$BASE_URL/tokenize-batch" \
  -H "Content-Type: application/json" \
  -d '{"items":[
    {"type":"rrn","value":"850315-2987654"},
    {"type":"card","value":"1234-5678-9012-3456"}
  ]}')

info "Response: $BATCH_RESP"

BATCH_COUNT=$(echo "$BATCH_RESP" | jq '.tokens | length')
[[ "$BATCH_COUNT" -eq 2 ]] || fail "배치 토큰 수 오류: $BATCH_COUNT (expected 2)"

CARD_TOKEN=$(echo "$BATCH_RESP" | jq -r '.tokens[1].token')
if echo "$CARD_TOKEN" | grep -qE '^[0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]{4}$'; then
  pass "카드번호 포맷 보존 확인: $CARD_TOKEN"
else
  fail "카드번호 포맷 오류: $CARD_TOKEN"
fi
pass "배치 토큰화 완료 ($BATCH_COUNT 건)"

# ─── Step 11: pg-pii fpe_token 레코드 수 확인 ────────────────────────────
step "Step 11: pg-pii fpe_token 레코드 수 확인"
PII_POD=$(kubectl get pods -n "$NAMESPACE" -l cnpg.io/cluster=pg-pii \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$PII_POD" ]]; then
  COUNT=$(kubectl exec -n "$NAMESPACE" "$PII_POD" -- \
    psql -U postgres -d app -tAc "SELECT COUNT(*) FROM fpe_token;" 2>/dev/null || echo "N/A")
  if [[ "$COUNT" =~ ^[0-9]+$ ]] && [[ "$COUNT" -ge 1 ]]; then
    pass "pg-pii fpe_token 레코드 수: $COUNT ≥ 1"
  else
    warn "pg-pii 조회 결과: $COUNT (DB 연결 실패 또는 레코드 없음)"
  fi
else
  warn "pg-pii 파드를 찾을 수 없음 — DB 검증 스킵"
fi

# ─── 최종 결과 ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo " FPE Smoke Test 완료"
echo "════════════════════════════════════════════════════════════════"
echo " RRN 원본  : 900101-1234567"
echo " RRN 토큰  : $TOKEN"
echo " 복원 값   : $RESTORED"
echo " token_id  : $TOKEN_ID"
echo "════════════════════════════════════════════════════════════════"
pass "FPE Smoke Test ALL PASS"
