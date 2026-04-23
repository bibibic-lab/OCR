#!/usr/bin/env bash
# ocr_worker_paddle_smoke.sh — PaddleOCR worker 배포 + smoke 테스트
#
# 테스트 항목:
#   1. pod Ready 대기 (최대 180초)
#   2. GET /healthz → {"status":"ok"}
#   3. GET /readyz → {"status":"ready", "engine":"PaddleOCR PP-OCRv5"}
#   4. POST /ocr (sample-id-korean.png) → count > 0 + items[0].text 포함 확인
#
# 사전 조건:
#   - kind cluster 'ocr-dev' 실행 중
#   - ocr-worker-paddle:v0.1.0 이미지 kind load 완료
#   - infra/manifests/ocr-worker-paddle/ apply 완료
#   - kubectl, curl, jq, nc 설치됨
#
# 사용법:
#   bash tests/smoke/ocr_worker_paddle_smoke.sh
#
# 종료 코드:
#   0 = 전체 통과, 1 = smoke 실패

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
step() { echo -e "\n${CYAN}══ $* ${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

NS="processing"
SVC="ocr-worker-paddle"
PF_PORT=18889  # smoke용 별도 포트 (run-paddle.sh 18888과 충돌 방지)
SAMPLE_IMAGE="tests/images/sample-id-korean.png"

PF_PID=""
cleanup() {
  [ -n "${PF_PID:-}" ] && kill "${PF_PID}" 2>/dev/null || true
}
trap cleanup EXIT

for cmd in kubectl curl jq nc; do
  command -v "$cmd" >/dev/null 2>&1 || { fail "$cmd 미설치"; }
done

# ── Step 1: 매니페스트 apply ──────────────────────────────────────────────────
step "Step 1: 매니페스트 apply"
kubectl apply -f infra/manifests/ocr-worker-paddle/deployment.yaml
kubectl apply -f infra/manifests/ocr-worker-paddle/network-policies.yaml
ok "apply 완료"

# ── Step 2: Pod Ready 대기 ────────────────────────────────────────────────────
step "Step 2: Pod Ready 대기 (최대 180초)"
kubectl -n "${NS}" wait --for=condition=Ready \
  pod -l "app.kubernetes.io/name=${SVC}" --timeout=180s
ok "pod Ready"

# ── Step 3: port-forward ─────────────────────────────────────────────────────
step "Step 3: port-forward (:${PF_PORT})"
lsof -ti :"${PF_PORT}" 2>/dev/null | xargs kill -9 2>/dev/null || true
kubectl -n "${NS}" port-forward "svc/${SVC}" "${PF_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 30); do
  nc -z 127.0.0.1 "${PF_PORT}" >/dev/null 2>&1 && break
  sleep 1
done
nc -z 127.0.0.1 "${PF_PORT}" >/dev/null 2>&1 || fail "port-forward 준비 시간 초과"
ok "port-forward ready"

# ── Step 4: /healthz ─────────────────────────────────────────────────────────
step "Step 4: GET /healthz"
HZ=$(curl -sf "http://localhost:${PF_PORT}/healthz")
echo "  응답: ${HZ}"
echo "${HZ}" | jq -e '.status == "ok"' >/dev/null || fail "/healthz 응답 이상"
ok "/healthz OK"

# ── Step 5: /readyz ───────────────────────────────────────────────────────────
step "Step 5: GET /readyz"
RZ=$(curl -sf "http://localhost:${PF_PORT}/readyz")
echo "  응답: ${RZ}"
echo "${RZ}" | jq -e '.status == "ready"' >/dev/null || fail "/readyz 응답 이상"
ok "/readyz OK"

# ── Step 6: POST /ocr ─────────────────────────────────────────────────────────
step "Step 6: POST /ocr (${SAMPLE_IMAGE})"
[ -f "${SAMPLE_IMAGE}" ] || fail "샘플 이미지 없음: ${SAMPLE_IMAGE}"
OCR_RESP=$(curl -sf -F "file=@${SAMPLE_IMAGE}" "http://localhost:${PF_PORT}/ocr")
COUNT=$(echo "${OCR_RESP}" | jq '.count')
FIRST_TEXT=$(echo "${OCR_RESP}" | jq -r '.items[0].text // "N/A"')
FIRST_CONF=$(echo "${OCR_RESP}" | jq '.items[0].confidence // 0')
info "  count=${COUNT}  items[0].text=${FIRST_TEXT}  conf=${FIRST_CONF}"
[ "${COUNT}" -gt 0 ] 2>/dev/null || fail "OCR 결과 없음 (count=0)"
ok "POST /ocr OK — count=${COUNT}, 첫 텍스트=${FIRST_TEXT}"

echo
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN} ocr-worker-paddle smoke: ALL PASSED${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
