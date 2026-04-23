#!/usr/bin/env bash
# run-paddle.sh — PaddleOCR PP-OCRv5 accuracy harness 실행 래퍼
#
# 기능:
#   1. ocr-worker-paddle service를 port-forward (18888:80)
#   2. run_accuracy.py --direct-ocr-endpoint 모드로 실행
#   3. paddle-baseline-<commit>.json 저장
#
# 사전 조건:
#   - kind cluster 'ocr-dev' 실행 중
#   - ocr-worker-paddle pod Running + Ready
#   - kubectl, python3, nc 설치됨
#
# 사용법:
#   bash tests/accuracy/run-paddle.sh
#   bash tests/accuracy/run-paddle.sh --verbose
#
# 종료 코드:
#   0 = 전체 통과, 1 = harness 실패, 2 = 환경 오류

set -euo pipefail

# ── 색상 출력 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
step() { echo -e "\n${CYAN}══ $* ${NC}"; }

VERBOSE=""
[ "${1:-}" = "--verbose" ] && VERBOSE="--verbose"

# ── 환경 확인 ─────────────────────────────────────────────────────────────────
for cmd in kubectl python3 nc; do
  command -v "$cmd" >/dev/null 2>&1 || { fail "$cmd 미설치"; }
done

# ── 경로 설정 ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

PADDLE_PF_PORT=18888
NS="processing"
SVC="ocr-worker-paddle"

PADDLE_PF_PID=""
cleanup() {
  info "port-forward 정리..."
  [ -n "${PADDLE_PF_PID:-}" ] && kill "${PADDLE_PF_PID}" 2>/dev/null || true
}
trap cleanup EXIT

wait_port() {
  local host="$1" port="$2" label="$3" max="${4:-30}"
  for _ in $(seq 1 "$max"); do
    nc -z "$host" "$port" >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "port-forward 대기 시간 초과: ${label} ${host}:${port}"
}

# ── Step 1: Pod Ready 확인 ────────────────────────────────────────────────────
step "Step 1: ocr-worker-paddle Pod Ready 확인"
kubectl -n "${NS}" get pod -l "app.kubernetes.io/name=${SVC}" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' >/dev/null 2>&1 \
  || fail "ocr-worker-paddle pod가 Running 상태가 아닙니다. kubectl -n ${NS} get pods 확인"
ok "pod Running 확인"

# ── Step 2: port-forward ─────────────────────────────────────────────────────
step "Step 2: ocr-worker-paddle port-forward (:${PADDLE_PF_PORT})"
lsof -ti :"${PADDLE_PF_PORT}" 2>/dev/null | xargs kill -9 2>/dev/null || true

kubectl -n "${NS}" port-forward "svc/${SVC}" "${PADDLE_PF_PORT}:80" >/dev/null 2>&1 &
PADDLE_PF_PID=$!
wait_port 127.0.0.1 "${PADDLE_PF_PORT}" "${SVC}" 30
ok "port-forward 준비 완료 (pid=${PADDLE_PF_PID})"

# readyz 확인
READYZ=$(curl -sf "http://localhost:${PADDLE_PF_PORT}/readyz" 2>/dev/null || echo '{}')
ok "readyz: ${READYZ}"

# ── Step 3: git commit hash ───────────────────────────────────────────────────
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
info "commit = ${COMMIT}"

# ── Step 4: accuracy harness 실행 ─────────────────────────────────────────────
step "Step 4: run_accuracy.py (direct OCR 모드)"

python3 tests/accuracy/run_accuracy.py \
  --direct-ocr-endpoint "http://localhost:${PADDLE_PF_PORT}" \
  --engine "PaddleOCR PP-OCRv5" \
  --fixtures "tests/accuracy/fixtures" \
  --out "tests/accuracy/reports" \
  --commit "${COMMIT}" \
  --min-success-rate 0.8 \
  ${VERBOSE}

info "완료 — reports 저장 위치: tests/accuracy/reports/"
