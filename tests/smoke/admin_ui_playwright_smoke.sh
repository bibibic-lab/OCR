#!/usr/bin/env bash
# ============================================================================
# admin_ui_playwright_smoke.sh — Playwright OIDC E2E 브라우저 자동화
#
# 목적:
#   Phase 1 Medium #5 — 실제 브라우저로 OIDC 로그인 + 업로드 + OCR 결과 검증
#
# 플로우:
#   1. port-forward: Keycloak(8443) + upload-api(18080) 시작
#   2. admin-ui를 로컬 dev 서버로 기동 (services/admin-ui npm run dev)
#      환경 변수: KEYCLOAK_ISSUER=https://localhost:8443/realms/ocr
#   3. Playwright 테스트 실행 (tests/e2e-ui)
#   4. 종료 시 port-forward + dev 서버 정리
#
# 사용:
#   chmod +x tests/smoke/admin_ui_playwright_smoke.sh
#   ./tests/smoke/admin_ui_playwright_smoke.sh
#
# 환경 변수(선택):
#   E2E_USER=submitter1       — 테스트 사용자
#   E2E_PASS=submitter1       — 테스트 비밀번호
#   SKIP_DEV_SERVER=1         — admin-ui dev 서버 자동 기동 스킵 (직접 기동한 경우)
#   SKIP_PORT_FORWARD=1       — port-forward 스킵 (이미 포워딩 중인 경우)
#   ADMIN_UI_URL=http://localhost:3000
#   KC_URL=https://localhost:8443
#   KEYCLOAK_CLIENT_SECRET=ocr-backoffice-dev-secret
#   PLAYWRIGHT_HEADED=1       — 브라우저 헤드 모드로 실행 (디버깅용)
#
# 의존성:
#   - kubectl (cluster access)
#   - node / npm / npx
#   - Playwright 설치: cd tests/e2e-ui && npm install && npx playwright install chromium
# ============================================================================
set -euo pipefail

# ── 색상 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS="${GREEN}[PASS]${NC}"; FAIL="${RED}[FAIL]${NC}"; INFO="${BLUE}[INFO]${NC}"; WARN="${YELLOW}[WARN]${NC}"

# ── 설정 ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
E2E_DIR="${REPO_ROOT}/tests/e2e-ui"
ADMIN_UI_DIR="${REPO_ROOT}/services/admin-ui"

ADMIN_UI_PORT="${ADMIN_UI_PORT:-3000}"
KC_PORT="${KC_PORT:-8443}"
UPLOAD_API_PORT="${UPLOAD_API_PORT:-18080}"

ADMIN_UI_URL="${ADMIN_UI_URL:-http://localhost:${ADMIN_UI_PORT}}"
KC_URL="${KC_URL:-https://localhost:${KC_PORT}}"
KC_ISSUER="${KC_URL}/realms/ocr"

E2E_USER="${E2E_USER:-submitter1}"
E2E_PASS="${E2E_PASS:-submitter1}"
KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-ocr-backoffice-dev-secret}"

PF_KC_PID=""
PF_API_PID=""
DEV_SERVER_PID=""
FAILED=0

log()  { echo -e "${INFO} $*"; }
pass() { echo -e "${PASS} $*"; }
warn() { echo -e "${WARN} $*"; }
fail() { echo -e "${FAIL} $*"; FAILED=1; }

# ── 정리 ──────────────────────────────────────────────────────────────────────
cleanup() {
  log "정리 시작..."

  if [[ -n "${DEV_SERVER_PID:-}" ]]; then
    log "admin-ui dev 서버 종료 (PID: ${DEV_SERVER_PID})"
    kill "${DEV_SERVER_PID}" 2>/dev/null || true
    # Next.js dev 서버의 자식 프로세스도 종료
    pkill -P "${DEV_SERVER_PID}" 2>/dev/null || true
  fi

  if [[ -n "${PF_KC_PID:-}" ]]; then
    log "Keycloak port-forward 종료 (PID: ${PF_KC_PID})"
    kill "${PF_KC_PID}" 2>/dev/null || true
  fi

  if [[ -n "${PF_API_PID:-}" ]]; then
    log "upload-api port-forward 종료 (PID: ${PF_API_PID})"
    kill "${PF_API_PID}" 2>/dev/null || true
  fi

  log "정리 완료"
}
trap cleanup EXIT

# ── 사전 검사 ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Playwright OIDC E2E Smoke — Phase 1 Medium #5"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

log "의존성 확인..."
command -v node >/dev/null 2>&1 || { fail "node 미설치"; exit 1; }
command -v npm  >/dev/null 2>&1 || { fail "npm 미설치"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { fail "kubectl 미설치"; exit 1; }

NODE_VER=$(node --version)
log "Node.js: ${NODE_VER}"

# ── Step 1: Playwright 의존성 설치 ────────────────────────────────────────────
echo -e "\n${BLUE}[Step 1]${NC} Playwright 의존성 설치"
cd "${E2E_DIR}"
if [[ ! -d node_modules ]]; then
  npm install --silent
  pass "npm install 완료"
else
  warn "node_modules 존재 — 스킵"
fi

# Playwright 브라우저 설치 확인
if ! npx playwright --version >/dev/null 2>&1; then
  fail "Playwright 설치 실패 — npm install 재실행 필요"
  exit 1
fi

# Chromium 설치 (미설치 시만)
if [[ ! -d "${HOME}/.cache/ms-playwright" ]] && [[ ! -d "${HOME}/Library/Caches/ms-playwright" ]]; then
  log "Chromium 설치 중..."
  npx playwright install chromium
  pass "Chromium 설치 완료"
else
  warn "Playwright 브라우저 캐시 존재 — 스킵"
fi

# ── Step 2: port-forward ─────────────────────────────────────────────────────
echo -e "\n${BLUE}[Step 2]${NC} Port-forward 설정"

if [[ "${SKIP_PORT_FORWARD:-0}" == "1" ]]; then
  warn "SKIP_PORT_FORWARD=1 — port-forward 스킵"
else
  # 기존 port-forward 정리
  pkill -f "kubectl.*port-forward.*keycloak" 2>/dev/null || true
  pkill -f "kubectl.*port-forward.*upload-api" 2>/dev/null || true
  sleep 1

  # Keycloak port-forward
  log "Keycloak port-forward 시작 (localhost:${KC_PORT} → svc/keycloak:443)"
  kubectl -n admin port-forward svc/keycloak "${KC_PORT}:443" \
    >"${REPO_ROOT}/tmp/pf-keycloak.log" 2>&1 &
  PF_KC_PID=$!
  sleep 2

  if ! kill -0 "${PF_KC_PID}" 2>/dev/null; then
    fail "Keycloak port-forward 기동 실패"
    cat "${REPO_ROOT}/tmp/pf-keycloak.log" 2>/dev/null || true
    exit 1
  fi
  pass "Keycloak port-forward 기동 (PID: ${PF_KC_PID})"

  # upload-api port-forward
  log "upload-api port-forward 시작 (localhost:${UPLOAD_API_PORT} → svc/upload-api:80)"
  kubectl -n dmz port-forward svc/upload-api "${UPLOAD_API_PORT}:80" \
    >"${REPO_ROOT}/tmp/pf-upload-api.log" 2>&1 &
  PF_API_PID=$!
  sleep 2

  if ! kill -0 "${PF_API_PID}" 2>/dev/null; then
    fail "upload-api port-forward 기동 실패"
    cat "${REPO_ROOT}/tmp/pf-upload-api.log" 2>/dev/null || true
    exit 1
  fi
  pass "upload-api port-forward 기동 (PID: ${PF_API_PID})"
fi

# ── Step 3: admin-ui dev 서버 기동 ───────────────────────────────────────────
echo -e "\n${BLUE}[Step 3]${NC} admin-ui dev 서버 기동"

mkdir -p "${REPO_ROOT}/tmp"

if [[ "${SKIP_DEV_SERVER:-0}" == "1" ]]; then
  warn "SKIP_DEV_SERVER=1 — dev 서버 스킵 (직접 기동 가정)"
else
  # .env.local 생성
  AUTH_SECRET=$(openssl rand -base64 32)
  cat > "${ADMIN_UI_DIR}/.env.local" <<EOF
KEYCLOAK_CLIENT_ID=ocr-backoffice
KEYCLOAK_CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET}
KEYCLOAK_ISSUER=${KC_ISSUER}
AUTH_SECRET=${AUTH_SECRET}
NEXTAUTH_URL=${ADMIN_UI_URL}
NEXT_PUBLIC_UPLOAD_API_BASE=http://localhost:${UPLOAD_API_PORT}
NODE_TLS_REJECT_UNAUTHORIZED=0
EOF
  log ".env.local 생성 완료"
  log "  KEYCLOAK_ISSUER=${KC_ISSUER}"
  log "  NEXTAUTH_URL=${ADMIN_UI_URL}"

  # dev 서버 기동
  log "Next.js dev 서버 기동 중..."
  cd "${ADMIN_UI_DIR}"
  npm run dev >"${REPO_ROOT}/tmp/admin-ui-dev.log" 2>&1 &
  DEV_SERVER_PID=$!

  # 서버 준비 대기 (최대 60초)
  log "admin-ui 준비 대기 (최대 60초)..."
  READY=0
  for i in $(seq 1 60); do
    if curl -s --connect-timeout 1 "${ADMIN_UI_URL}/api/health" >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 1
  done

  if [[ "${READY}" == "0" ]]; then
    fail "admin-ui dev 서버 시작 타임아웃"
    tail -20 "${REPO_ROOT}/tmp/admin-ui-dev.log" 2>/dev/null || true
    exit 1
  fi
  pass "admin-ui dev 서버 준비 완료 (PID: ${DEV_SERVER_PID})"
fi

# ── Step 4: Playwright 테스트 실행 ───────────────────────────────────────────
echo -e "\n${BLUE}[Step 4]${NC} Playwright 테스트 실행"
cd "${E2E_DIR}"

PLAYWRIGHT_ARGS=""
if [[ "${PLAYWRIGHT_HEADED:-0}" == "1" ]]; then
  PLAYWRIGHT_ARGS="--headed"
fi

export ADMIN_UI_URL KC_URL E2E_USER E2E_PASS

log "테스트 시작..."
log "  ADMIN_UI_URL=${ADMIN_UI_URL}"
log "  KC_URL=${KC_URL}"
log "  E2E_USER=${E2E_USER}"
echo ""

if npx playwright test ${PLAYWRIGHT_ARGS} 2>&1 | tee "${REPO_ROOT}/tmp/playwright-results.log"; then
  echo ""
  pass "Playwright 테스트 전체 PASS"
else
  PLAYWRIGHT_EXIT=$?
  echo ""
  fail "Playwright 테스트 실패 (exit: ${PLAYWRIGHT_EXIT})"
  FAILED=1
fi

# ── 결과 요약 ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
if [[ "${FAILED}" == "0" ]]; then
  echo -e "  ${GREEN}E2E SMOKE TEST PASSED${NC}"
else
  echo -e "  ${RED}E2E SMOKE TEST FAILED${NC}"
  echo ""
  echo "  로그: ${REPO_ROOT}/tmp/playwright-results.log"
  echo "  리포트: ${E2E_DIR}/playwright-report/index.html"
  echo "  열기: npx playwright show-report (tests/e2e-ui/ 에서)"
fi
echo "============================================================"
echo ""

exit "${FAILED}"
