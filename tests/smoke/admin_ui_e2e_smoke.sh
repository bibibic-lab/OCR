#!/usr/bin/env bash
# ============================================================================
# admin_ui_e2e_smoke.sh — B3-T4 admin-ui end-to-end smoke test
#
# 목적:
#   1. Docker 이미지 admin-ui:v0.1.0 빌드
#   2. kind 클러스터에 이미지 로드
#   3. admin ns Secret(admin-ui-env, ocr-internal-ca) 존재 보장
#   4. k8s 매니페스트 apply
#   5. Deployment Ready 대기
#   6. port-forward 시작 (localhost:3030 → admin-ui svc:80)
#   7. /api/health 200 OK 확인
#   8. 홈 페이지 응답 확인
#
# 참고:
#   - OIDC 브라우저 플로우(로그인 → 업로드 → OCR 결과)는 CSRF+state+세션 쿠키
#     조합이 필요하여 curl 자동화 불가. 수동 검증 체크리스트를 출력한다.
#
# 사용:
#   chmod +x tests/smoke/admin_ui_e2e_smoke.sh
#   ./tests/smoke/admin_ui_e2e_smoke.sh
#
# 환경 변수(선택):
#   SKIP_BUILD=1          — Docker 빌드 스킵 (이미 빌드된 경우)
#   SKIP_KIND_LOAD=1      — kind load 스킵 (이미 로드된 경우)
#   PORT_FORWARD_PORT=3030 — 기본 포트 (변경 가능)
# ============================================================================
set -euo pipefail

# ── 색상 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS="${GREEN}[PASS]${NC}"; FAIL="${RED}[FAIL]${NC}"; INFO="${BLUE}[INFO]${NC}"; WARN="${YELLOW}[WARN]${NC}"

# ── 설정 ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IMAGE_NAME="admin-ui:v0.1.0"
KIND_CLUSTER="ocr-dev"
NAMESPACE="admin"
SVC_NAME="admin-ui"
LOCAL_PORT="${PORT_FORWARD_PORT:-3030}"
MANIFEST_DIR="${REPO_ROOT}/infra/manifests/admin-ui"
ADMIN_UI_DIR="${REPO_ROOT}/services/admin-ui"
PF_PID=""
FAILED=0

log() { echo -e "${INFO} $*"; }
pass() { echo -e "${PASS} $*"; }
warn() { echo -e "${WARN} $*"; }
fail() { echo -e "${FAIL} $*"; FAILED=1; }

cleanup() {
  if [[ -n "${PF_PID}" ]]; then
    log "port-forward 종료 (PID: ${PF_PID})"
    kill "${PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── OrbStack Docker 소켓 감지 ─────────────────────────────────────────────────
ORBSTACK_SOCK="${HOME}/.orbstack/run/docker.sock"
if [[ -S "${ORBSTACK_SOCK}" ]]; then
  export KIND_EXPERIMENTAL_PROVIDER=docker
  DOCKER_KIND="env DOCKER_HOST=unix://${ORBSTACK_SOCK} docker"
  KIND_CMD="env DOCKER_HOST=unix://${ORBSTACK_SOCK} kind"
  log "OrbStack Docker 소켓 감지: ${ORBSTACK_SOCK}"
else
  DOCKER_KIND="docker"
  KIND_CMD="kind"
fi

echo ""
echo "============================================================"
echo "  admin-ui E2E Smoke Test — B3-T4"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

# ── Step 1: Docker 이미지 빌드 ───────────────────────────────────────────────
echo -e "\n${BLUE}[Step 1]${NC} Docker 이미지 빌드: ${IMAGE_NAME}"
if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  warn "SKIP_BUILD=1 — 빌드 스킵"
else
  cd "${ADMIN_UI_DIR}"
  if docker build --platform linux/amd64 -t "${IMAGE_NAME}" . ; then
    SIZE=$(docker images "${IMAGE_NAME}" --format "{{.Size}}" 2>/dev/null || echo "unknown")
    pass "이미지 빌드 완료. 크기: ${SIZE}"
  else
    fail "이미지 빌드 실패"
    exit 1
  fi
fi

# ── Step 2: kind load ────────────────────────────────────────────────────────
echo -e "\n${BLUE}[Step 2]${NC} kind 클러스터에 이미지 로드"
if [[ "${SKIP_KIND_LOAD:-0}" == "1" ]]; then
  warn "SKIP_KIND_LOAD=1 — kind load 스킵"
else
  # OrbStack kind는 Docker Desktop 이미지를 못 봄 → 이미지를 OrbStack으로 복사
  if [[ -S "${ORBSTACK_SOCK}" ]]; then
    log "OrbStack으로 이미지 복사 중..."
    if docker save "${IMAGE_NAME}" | DOCKER_HOST="unix://${ORBSTACK_SOCK}" docker load ; then
      log "OrbStack Docker에 이미지 로드 완료"
    else
      fail "OrbStack Docker 이미지 로드 실패"
      exit 1
    fi
  fi

  if eval "${KIND_CMD} load docker-image ${IMAGE_NAME} --name ${KIND_CLUSTER}" ; then
    pass "kind 클러스터에 이미지 로드 완료"
  else
    fail "kind load 실패"
    exit 1
  fi
fi

# ── Step 3: Secret 존재 보장 ─────────────────────────────────────────────────
echo -e "\n${BLUE}[Step 3]${NC} Secret 존재 확인 및 생성"

# admin-ui-env
if kubectl -n "${NAMESPACE}" get secret admin-ui-env &>/dev/null; then
  pass "admin-ui-env Secret 존재"
else
  warn "admin-ui-env Secret 없음 — 생성 중..."
  AUTH_SECRET=$(openssl rand -base64 32)
  kubectl -n "${NAMESPACE}" create secret generic admin-ui-env \
    --from-literal=AUTH_SECRET="${AUTH_SECRET}" \
    --from-literal=KEYCLOAK_CLIENT_SECRET="ocr-backoffice-dev-secret" \
    --dry-run=client -o yaml | kubectl apply -f -
  pass "admin-ui-env Secret 생성 완료"
fi

# ocr-internal-ca (dmz ns에서 복사)
if kubectl -n "${NAMESPACE}" get secret ocr-internal-ca &>/dev/null; then
  pass "ocr-internal-ca Secret 존재"
else
  warn "ocr-internal-ca Secret 없음 — dmz ns에서 복사 중..."
  if kubectl -n dmz get secret ocr-internal-ca &>/dev/null; then
    kubectl -n dmz get secret ocr-internal-ca -o yaml | \
      python3 -c "
import sys, yaml
data = yaml.safe_load(sys.stdin)
data['metadata'] = {'name': 'ocr-internal-ca', 'namespace': '${NAMESPACE}'}
print(yaml.dump(data))
" | kubectl apply -f -
    pass "ocr-internal-ca Secret 복사 완료"
  else
    fail "dmz ns에도 ocr-internal-ca가 없음 — CA Secret이 필요합니다"
    exit 1
  fi
fi

# ── Step 4: 매니페스트 apply ─────────────────────────────────────────────────
echo -e "\n${BLUE}[Step 4]${NC} k8s 매니페스트 apply"
if kubectl apply -f "${MANIFEST_DIR}/" ; then
  pass "매니페스트 apply 완료"
else
  fail "매니페스트 apply 실패"
  exit 1
fi

# upload-api NetworkPolicy 업데이트
kubectl apply -f "${REPO_ROOT}/infra/manifests/upload-api/network-policies.yaml" 2>/dev/null || true

# ── Step 5: Deployment Ready 대기 ────────────────────────────────────────────
echo -e "\n${BLUE}[Step 5]${NC} Deployment Ready 대기 (최대 120초)"
if kubectl -n "${NAMESPACE}" rollout status deployment/admin-ui --timeout=120s ; then
  POD=$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=admin-ui -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  READY=$(kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "unknown")
  RESTARTS=$(kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
  pass "Deployment Ready. Pod: ${POD}, Ready: ${READY}, Restarts: ${RESTARTS}"
else
  fail "Deployment rollout 타임아웃"
  kubectl -n "${NAMESPACE}" describe pod -l app.kubernetes.io/name=admin-ui 2>/dev/null | tail -30
  exit 1
fi

# ── Step 6: port-forward 시작 ────────────────────────────────────────────────
echo -e "\n${BLUE}[Step 6]${NC} port-forward 시작 (localhost:${LOCAL_PORT} → svc/${SVC_NAME}:80)"

# 기존 port-forward 정리
pkill -f "kubectl.*port-forward.*${SVC_NAME}" 2>/dev/null || true
sleep 1

kubectl -n "${NAMESPACE}" port-forward "svc/${SVC_NAME}" "${LOCAL_PORT}:80" &>/tmp/pf-admin-ui.log &
PF_PID=$!

# 포트 오픈 대기 (최대 15초)
for i in $(seq 1 15); do
  if curl -s --connect-timeout 1 "http://localhost:${LOCAL_PORT}/api/health" &>/dev/null; then
    break
  fi
  sleep 1
done

if kill -0 "${PF_PID}" 2>/dev/null; then
  pass "port-forward 기동 완료 (PID: ${PF_PID})"
else
  fail "port-forward 실패"
  cat /tmp/pf-admin-ui.log 2>/dev/null
  exit 1
fi

# ── Step 7: /api/health 확인 ─────────────────────────────────────────────────
echo -e "\n${BLUE}[Step 7]${NC} /api/health 응답 확인"
HEALTH_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${LOCAL_PORT}/api/health" 2>/dev/null)
HEALTH_BODY=$(curl -s "http://localhost:${LOCAL_PORT}/api/health" 2>/dev/null)

if [[ "${HEALTH_RESPONSE}" == "200" ]]; then
  pass "/api/health → HTTP ${HEALTH_RESPONSE} | Body: ${HEALTH_BODY}"
else
  fail "/api/health → HTTP ${HEALTH_RESPONSE} (200 기대)"
fi

# ── Step 8: 홈 페이지 응답 확인 ──────────────────────────────────────────────
echo -e "\n${BLUE}[Step 8]${NC} 홈 페이지 응답 확인"
HOME_CODE=$(curl -s -o /dev/null -w "%{http_code}" -L --max-redirs 3 "http://localhost:${LOCAL_PORT}/" 2>/dev/null)
if [[ "${HOME_CODE}" =~ ^(200|307|302|301)$ ]]; then
  pass "홈 페이지 → HTTP ${HOME_CODE}"
else
  fail "홈 페이지 → HTTP ${HOME_CODE} (200/30x 기대)"
fi

# ── 결과 요약 ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
if [[ "${FAILED}" == "0" ]]; then
  echo -e "  ${GREEN}SMOKE TEST PASSED${NC}"
else
  echo -e "  ${RED}SMOKE TEST FAILED${NC}"
fi
echo "============================================================"
echo ""

# ── 수동 검증 체크리스트 ─────────────────────────────────────────────────────
echo -e "${YELLOW}수동 검증 체크리스트 (OIDC 플로우):${NC}"
echo ""
echo "  port-forward가 유지되는 동안 브라우저에서 다음을 확인하세요."
echo ""
echo "  1. http://localhost:${LOCAL_PORT} 접속"
echo "     → 인증 안 된 경우 Keycloak 로그인 페이지로 리디렉션"
echo ""
echo "  2. Keycloak 로그인:"
echo "     - 사용자: dev-admin"
echo "     - 비밀번호: kubectl -n admin get secret keycloak-dev-creds -o jsonpath='{.data.dev-admin-password}' | base64 -d"
echo ""
echo "  3. 로그인 후 대시보드 진입 확인"
echo ""
echo "  4. '문서 업로드' 메뉴 → 이미지 파일 선택 → 업로드 클릭"
echo "     예시 파일: tests/images/sample-id-korean.png (없으면 임의 PNG)"
echo ""
echo "  5. 상태가 PENDING → OCR_IN_PROGRESS → OCR_DONE으로 변경 확인"
echo ""
echo "  6. 결과 페이지에서 bbox 오버레이 렌더링 확인"
echo ""
echo "  port-forward 유지 명령:"
echo "    kubectl -n admin port-forward svc/admin-ui ${LOCAL_PORT}:80"
echo ""
echo "  Keycloak port-forward (OIDC 리디렉션 대상):"
echo "    kubectl -n admin port-forward svc/keycloak 8443:443"
echo "    NEXTAUTH_URL을 https://localhost:8443 으로 재설정 필요 (개발 환경 한정)"
echo ""

exit "${FAILED}"
