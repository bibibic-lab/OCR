#!/usr/bin/env bash
# integration_hub_smoke.sh — Integration Hub E2E 스모크 테스트
#
# 절차:
#   1. Docker 이미지 빌드 (integration-hub:v0.1.0)
#   2. kind load docker-image
#   3. kubectl apply manifests
#   4. Deployment Ready 대기
#   5. port-forward 18090:8080
#   6. 3개 엔드포인트 smoke (verify/id-card, timestamp, ocsp)
#   7. 결과 요약
#
# 전제:
#   - kind 클러스터 실행 중 (kubectl context = kind-ocr or kind)
#   - JAVA_HOME=/usr/local/Cellar/openjdk@21/21.0.11/libexec/openjdk.jdk/Contents/Home
#   - processing 네임스페이스 존재

set -euo pipefail

# ── 설정 ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SERVICE_DIR="${REPO_ROOT}/services/integration-hub"
MANIFEST_DIR="${REPO_ROOT}/infra/manifests/integration-hub"

IMAGE_NAME="integration-hub"
IMAGE_TAG="v0.1.0"
NAMESPACE="processing"
LOCAL_PORT=18090
TARGET_PORT=8080
PF_PID_FILE="/tmp/integration-hub-pf.pid"

export JAVA_HOME="${JAVA_HOME:-/usr/local/Cellar/openjdk@21/21.0.11/libexec/openjdk.jdk/Contents/Home}"
export PATH="${JAVA_HOME}/bin:${PATH}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

SMOKE_PASS=0
SMOKE_FAIL=0

check() {
    local name="$1"
    local result="$2"
    local expected="$3"
    if echo "${result}" | grep -q "${expected}"; then
        pass "${name}"
        SMOKE_PASS=$((SMOKE_PASS + 1))
    else
        fail "${name}: expected '${expected}' in response. Got: ${result}"
        SMOKE_FAIL=$((SMOKE_FAIL + 1))
    fi
}

cleanup() {
    info "Cleanup: port-forward 종료..."
    if [ -f "${PF_PID_FILE}" ]; then
        kill "$(cat "${PF_PID_FILE}")" 2>/dev/null || true
        rm -f "${PF_PID_FILE}"
    fi
}
trap cleanup EXIT

# ── Step 1: 이미지 빌드 ───────────────────────────────────────────────────────
info "Step 1: Docker 이미지 빌드 (${IMAGE_NAME}:${IMAGE_TAG})"
docker build \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    "${SERVICE_DIR}"
pass "이미지 빌드 완료"

# ── Step 2: kind load ─────────────────────────────────────────────────────────
info "Step 2: kind load docker-image ${IMAGE_NAME}:${IMAGE_TAG}"
# OrbStack + kind 환경: desktop-linux Docker context의 이미지를 OrbStack context로 이전 후 kind load
ORBSTACK_SOCK="/Users/$(whoami)/.orbstack/run/docker.sock"
if [ -S "${ORBSTACK_SOCK}" ]; then
    info "OrbStack 환경 감지 — 이미지를 OrbStack context로 전송"
    docker save "${IMAGE_NAME}:${IMAGE_TAG}" | DOCKER_HOST="unix://${ORBSTACK_SOCK}" docker load
    DOCKER_HOST="unix://${ORBSTACK_SOCK}" kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}" --name ocr-dev
else
    kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}"
fi
pass "kind load 완료"

# ── Step 3: manifest apply ────────────────────────────────────────────────────
info "Step 3: kubectl apply manifests"
kubectl apply -f "${MANIFEST_DIR}/service.yaml"
kubectl apply -f "${MANIFEST_DIR}/deployment.yaml"
kubectl apply -f "${MANIFEST_DIR}/network-policies.yaml"
pass "manifests apply 완료"

# ── Step 4: Deployment Ready 대기 ────────────────────────────────────────────
info "Step 4: Deployment Ready 대기 (최대 120초)..."
kubectl rollout status deployment/integration-hub \
    -n "${NAMESPACE}" \
    --timeout=120s
pass "Deployment Ready"

# ── Step 5: port-forward ──────────────────────────────────────────────────────
info "Step 5: port-forward ${LOCAL_PORT}:${TARGET_PORT}"
kubectl port-forward \
    -n "${NAMESPACE}" \
    "svc/integration-hub" \
    "${LOCAL_PORT}:${TARGET_PORT}" \
    &>/tmp/integration-hub-pf.log &
echo $! > "${PF_PID_FILE}"

# port-forward 안정화 대기
sleep 3
info "port-forward PID: $(cat "${PF_PID_FILE}")"

BASE_URL="http://localhost:${LOCAL_PORT}"

# ── Step 6: Smoke Tests ───────────────────────────────────────────────────────
info "Step 6: 3개 엔드포인트 스모크"

# --- /verify/id-card ---
info "6.1 POST /verify/id-card"
RESP_ID=$(curl -s -X POST "${BASE_URL}/verify/id-card" \
    -H "Content-Type: application/json" \
    -d '{"name":"홍길동","rrn":"9001011234567","issue_date":"20200315"}' \
    || echo "CURL_ERROR")
echo "  응답: ${RESP_ID}"
check "/verify/id-card → valid field" "${RESP_ID}" '"valid"'
check "/verify/id-card → agency_tx_id field" "${RESP_ID}" '"agency_tx_id"'

# --- /timestamp ---
info "6.2 POST /timestamp"
RESP_TSA=$(curl -s -X POST "${BASE_URL}/timestamp" \
    -H "Content-Type: application/json" \
    -d "{\"sha256\":\"$(printf 'a%.0s' {1..64})\"}" \
    || echo "CURL_ERROR")
echo "  응답: ${RESP_TSA}"
check "/timestamp → token field" "${RESP_TSA}" '"token"'
check "/timestamp → gen_time field" "${RESP_TSA}" '"gen_time"'

# --- /ocsp ---
info "6.3 POST /ocsp"
RESP_OCSP=$(curl -s -X POST "${BASE_URL}/ocsp" \
    -H "Content-Type: application/json" \
    -d '{"issuer_cn":"KISA-RootCA-G1","serial":"0123456789abcdef"}' \
    || echo "CURL_ERROR")
echo "  응답: ${RESP_OCSP}"
check "/ocsp → status field" "${RESP_OCSP}" '"status"'
check "/ocsp → good" "${RESP_OCSP}" 'good'

# ── Step 7: 결과 요약 ─────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Integration Hub Smoke 결과"
echo "════════════════════════════════════════════════════════"
echo -e "  PASS: ${GREEN}${SMOKE_PASS}${NC}"
echo -e "  FAIL: ${RED}${SMOKE_FAIL}${NC}"
echo "════════════════════════════════════════════════════════"

if [ "${SMOKE_FAIL}" -gt 0 ]; then
    echo -e "${RED}스모크 실패. 로그 확인:${NC}"
    echo "  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=integration-hub --tail=50"
    exit 1
else
    pass "모든 스모크 통과!"
    exit 0
fi
