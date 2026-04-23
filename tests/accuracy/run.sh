#!/usr/bin/env bash
# run.sh — OCR 정확도 harness 실행 래퍼
#
# 기능:
#   1. Keycloak cluster-internal token 발급 (upload_api_e2e_smoke.sh 패턴 재사용)
#   2. upload-api port-forward (18080)
#   3. run_accuracy.py 실행
#   4. 결과 reports/ 저장
#
# 사전 조건:
#   - kind cluster 'ocr-dev' 실행 중
#   - upload-api, keycloak, ocr-worker pod 모두 Running
#   - kubectl, jq, curl, python3 설치됨
#
# 사용법:
#   bash tests/accuracy/run.sh
#   bash tests/accuracy/run.sh 2>&1 | tee tests/accuracy/reports/baseline.md
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

# ── 환경 확인 ─────────────────────────────────────────────────────────────────
for cmd in kubectl jq curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { fail "$cmd 미설치"; }
done

# ── 경로 설정 ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

KIND_CLUSTER="ocr-dev"
API_PF_PORT=18080

# OrbStack 컨텍스트 자동 감지 (upload_api_e2e_smoke.sh 동일 패턴)
ORBSTACK_SOCK="unix:///Users/jimmy/.orbstack/run/docker.sock"
if DOCKER_HOST="${ORBSTACK_SOCK}" kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
  export DOCKER_HOST="${ORBSTACK_SOCK}"
  info "OrbStack 컨텍스트에서 kind cluster '${KIND_CLUSTER}' 발견"
fi

# port-forward PID
API_PF_PID=""

cleanup() {
  info "port-forward 정리..."
  [ -n "${API_PF_PID:-}" ] && kill "${API_PF_PID}" 2>/dev/null || true
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

# ── Step 1: Keycloak token 발급 (cluster 내부) ────────────────────────────────
# upload_api_e2e_smoke.sh §Step(d) 와 동일한 로직:
#   upload-api pod를 통해 cluster-internal URL로 token 발급
#   → iss claim이 "keycloak.admin.svc.cluster.local" 으로 발급되어 JWT 검증 통과
step "Step 1: Keycloak access_token 획득 (cluster 내부)"

CLIENT_SECRET=$(kubectl -n admin get secret keycloak-dev-creds \
  -o jsonpath='{.data.backoffice-client-secret}' | base64 -d)
DEV_ADMIN_PW=$(kubectl -n admin get secret keycloak-dev-creds \
  -o jsonpath='{.data.dev-admin-password}' | base64 -d)
[ -n "${CLIENT_SECRET}" ] && [ -n "${DEV_ADMIN_PW}" ] \
  || fail "keycloak-dev-creds Secret에서 자격증명 로드 실패"

UPLOAD_POD=$(kubectl -n dmz get pod -l app.kubernetes.io/name=upload-api \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "${UPLOAD_POD}" ] || fail "upload-api pod를 찾을 수 없음"

TOKEN=$(kubectl -n dmz exec "${UPLOAD_POD}" -- curl -sk \
  "https://keycloak.admin.svc.cluster.local/realms/ocr/protocol/openid-connect/token" \
  -d "client_id=ocr-backoffice" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=dev-admin" \
  -d "password=${DEV_ADMIN_PW}" \
  -d "grant_type=password" 2>/dev/null | jq -r '.access_token' 2>/dev/null)

[ -n "${TOKEN}" ] && [ "${TOKEN}" != "null" ] \
  || fail "Keycloak access_token 발급 실패"
ok "access_token 발급 성공 (${#TOKEN} chars)"

# ── Step 2: upload-api port-forward ──────────────────────────────────────────
step "Step 2: upload-api port-forward (:${API_PF_PORT})"

# 기존 port-forward 정리
lsof -ti :"${API_PF_PORT}" 2>/dev/null | xargs kill -9 2>/dev/null || true

kubectl -n dmz port-forward svc/upload-api "${API_PF_PORT}:80" >/dev/null 2>&1 &
API_PF_PID=$!
wait_port 127.0.0.1 "${API_PF_PORT}" "upload-api" 30
ok "port-forward 준비 완료 (pid=${API_PF_PID})"

# ── Step 3: git commit hash 획득 ─────────────────────────────────────────────
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
info "commit = ${COMMIT}"

# ── Step 4: 정확도 harness 실행 ───────────────────────────────────────────────
step "Step 3: run_accuracy.py 실행"

python3 tests/accuracy/run_accuracy.py \
  --endpoint "http://localhost:${API_PF_PORT}" \
  --token "${TOKEN}" \
  --fixtures "tests/accuracy/fixtures" \
  --out "tests/accuracy/reports" \
  --commit "${COMMIT}"

info "완료 — reports 저장 위치: tests/accuracy/reports/"
