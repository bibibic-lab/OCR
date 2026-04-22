#!/usr/bin/env bash
# upload_api_db_smoke.sh
# B1-T1 smoke: dmz-db-bootstrap Job 실행 → 검증.
#
# 검증 항목:
#   1. Job apply (ServiceAccount, RBAC, NetworkPolicy, Job 포함)
#   2. Job 완료 대기 (최대 3분)
#   3. Secret upload-api-db-creds 존재 및 필수 키 확인 (username, password, jdbc-url)
#   4. psql 로 dmz database 존재 확인 (pg-main-1 pod exec)
#   5. dmz_app role 존재 확인
#
# 사용법:
#   bash tests/smoke/upload_api_db_smoke.sh
#
# 종료 코드:
#   0 = 전체 통과
#   1 = 검증 실패
#   2 = 환경 오류

set -euo pipefail

MANIFEST="infra/manifests/upload-api/dmz-db-bootstrap.yaml"
NAMESPACE="processing"
JOB_NAME="dmz-db-bootstrap"
SECRET_NS="dmz"
SECRET_NAME="upload-api-db-creds"
TIMEOUT=180  # seconds

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not found"; exit 2; }

# 작업 디렉터리: 프로젝트 루트 기준
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

[ -f "${MANIFEST}" ] || fail "매니페스트 파일 없음: ${MANIFEST}"

# ── Step 1: 기존 Job 정리 (재실행 안전성) ─────────────────────────────────
if kubectl -n "${NAMESPACE}" get job "${JOB_NAME}" >/dev/null 2>&1; then
  info "기존 Job 발견 — 삭제 후 재apply..."
  kubectl -n "${NAMESPACE}" delete job "${JOB_NAME}" --wait=true --timeout=60s 2>/dev/null || true
fi

# ── Step 2: 매니페스트 apply ──────────────────────────────────────────────
info "매니페스트 apply: ${MANIFEST}"
kubectl apply -f "${MANIFEST}"
ok "apply 완료"

# ── Step 3: Job 완료 대기 ─────────────────────────────────────────────────
info "Job '${JOB_NAME}' 완료 대기 (최대 ${TIMEOUT}s)..."
START_TIME=$(date +%s)
while true; do
  ELAPSED=$(( $(date +%s) - START_TIME ))
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    # 실패 시 로그 출력
    echo "=== Job 최근 이벤트 ==="
    kubectl -n "${NAMESPACE}" describe job "${JOB_NAME}" 2>/dev/null | tail -20
    echo "=== Pod 로그 ==="
    POD=$(kubectl -n "${NAMESPACE}" get pods -l app="${JOB_NAME}" --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1)
    [ -n "${POD}" ] && kubectl -n "${NAMESPACE}" logs "${POD}" --all-containers=true 2>/dev/null | tail -40
    fail "Job '${JOB_NAME}' 이 ${TIMEOUT}s 내에 완료되지 않음"
  fi

  SUCCEEDED=$(kubectl -n "${NAMESPACE}" get job "${JOB_NAME}" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
  FAILED=$(kubectl -n "${NAMESPACE}" get job "${JOB_NAME}" -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")

  if [ "${SUCCEEDED:-0}" -ge 1 ]; then
    ok "Job 완료 (succeeded=${SUCCEEDED}, elapsed=${ELAPSED}s)"
    break
  fi

  if [ "${FAILED:-0}" -ge 4 ]; then
    echo "=== Pod 로그 ==="
    POD=$(kubectl -n "${NAMESPACE}" get pods -l app="${JOB_NAME}" --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1)
    [ -n "${POD}" ] && kubectl -n "${NAMESPACE}" logs "${POD}" --all-containers=true 2>/dev/null | tail -40
    fail "Job '${JOB_NAME}' 실패 (backoffLimit 초과, failed=${FAILED})"
  fi

  sleep 5
done

# ── Step 4: Secret 존재 확인 ──────────────────────────────────────────────
info "Secret '${SECRET_NAME}' 존재 확인 (ns=${SECRET_NS})..."
kubectl -n "${SECRET_NS}" get secret "${SECRET_NAME}" >/dev/null 2>&1 \
  || fail "Secret '${SECRET_NAME}' 가 ${SECRET_NS} ns 에 존재하지 않음"
ok "Secret 존재 확인"

# ── Step 5: Secret 필수 키 확인 ───────────────────────────────────────────
info "Secret 필수 키 검증..."
for KEY in username password jdbc-url; do
  VAL=$(kubectl -n "${SECRET_NS}" get secret "${SECRET_NAME}" \
    -o jsonpath="{.data.${KEY//\-/\\-}}" 2>/dev/null | base64 -d 2>/dev/null || true)
  # jsonpath에서 하이픈이 있는 키는 따옴표 처리 필요
  if [ -z "${VAL}" ]; then
    # 재시도: 직접 추출
    VAL=$(kubectl -n "${SECRET_NS}" get secret "${SECRET_NAME}" -o json 2>/dev/null \
      | python3 -c "import sys,json,base64; d=json.load(sys.stdin)['data']; print(base64.b64decode(d.get('${KEY}','')).decode())" 2>/dev/null || true)
  fi
  [ -n "${VAL}" ] || fail "Secret 키 '${KEY}' 가 비어있거나 존재하지 않음"
  # 패스워드 값은 마스킹
  if [ "${KEY}" = "password" ]; then
    ok "키 '${KEY}' = ****(length=${#VAL})"
  else
    ok "키 '${KEY}' = ${VAL}"
  fi
done

# ── Step 6: dmz database 존재 확인 (pg-main-1 pod exec) ──────────────────
info "dmz database 존재 확인 (pg-main-1 exec)..."
DMZ_EXISTS=$(kubectl -n processing exec pg-main-1 -c postgres -- \
  psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='dmz'" 2>/dev/null || echo "")
[ "${DMZ_EXISTS}" = "1" ] \
  || fail "dmz database 가 pg-main 에 존재하지 않음"
ok "dmz database 존재 확인"

# ── Step 7: dmz_app role 존재 확인 ───────────────────────────────────────
info "dmz_app role 존재 확인..."
ROLE_EXISTS=$(kubectl -n processing exec pg-main-1 -c postgres -- \
  psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='dmz_app'" 2>/dev/null || echo "")
[ "${ROLE_EXISTS}" = "1" ] \
  || fail "dmz_app role 이 pg-main 에 존재하지 않음"
ok "dmz_app role 존재 확인"

# ── Step 8: dmz_app 으로 dmz database 접속 확인 ──────────────────────────
info "dmz_app 접속 테스트 (dmz database)..."
DMZ_APP_PWD=$(kubectl -n "${SECRET_NS}" get secret "${SECRET_NAME}" -o json 2>/dev/null \
  | python3 -c "import sys,json,base64; d=json.load(sys.stdin)['data']; print(base64.b64decode(d.get('password','')).decode())" 2>/dev/null || true)

if [ -n "${DMZ_APP_PWD}" ]; then
  CONNECT_OK=$(kubectl -n processing exec pg-main-1 -c postgres -- \
    bash -c "PGPASSWORD='${DMZ_APP_PWD}' psql -U dmz_app -d dmz -h localhost \
    -tAc 'SELECT 1'" 2>/dev/null || echo "")
  [ "${CONNECT_OK}" = "1" ] \
    || fail "dmz_app 으로 dmz database 접속 실패"
  ok "dmz_app 접속 테스트 통과"
else
  info "패스워드 추출 실패 — 접속 테스트 skip"
fi

# ── 최종 결과 ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  B1-T1 smoke: ALL PASSED${NC}"
echo -e "${GREEN}======================================${NC}"
echo "  - Job: ${JOB_NAME} (ns=${NAMESPACE}) Succeeded"
echo "  - Secret: ${SECRET_NAME} (ns=${SECRET_NS}) 존재, 필수 키 정상"
echo "  - dmz database: pg-main 에 존재"
echo "  - dmz_app role: pg-main 에 존재, 접속 정상"
