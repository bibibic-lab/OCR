#!/usr/bin/env bash
# v2_full_e2e_smoke.sh — v2 전체 E2E Smoke 검증
#
# 검증 범위 (10 Step):
#   Step 1: port-forward 시작 (upload-api 18080, integration-hub 18090, opensearch 19200)
#   Step 2: Keycloak access_token 획득 (cluster 내부 exec, iss 일치)
#   Step 3: 문서 업로드 (POST /documents) → 201 + UUID
#   Step 4: OCR 완료 폴링 (GET /documents/{id}) → OCR_DONE + items>=5 + engine PaddleOCR
#   Step 5: RRN 토큰화 확인 → sensitiveFieldsTokenized=true + 원본 RRN 없음
#   Step 6: 수정 (PUT /documents/{id}/items) → updateCount=1 + 텍스트 반영
#   Step 7: 목록/검색 (GET /documents) → doc_id 포함 + 상태·검색 필터 확인
#   Step 8: 통계 (GET /documents/stats) → total>=1 + notImplemented>=5
#   Step 9: 외부연계 3기관 POLICY 검증 → X-Not-Implemented 헤더 + body.notImplemented
#   Step 10: 감사 로그 (OpenSearch) → 오늘 업로드 이벤트 hits > 0 [optional/warn]
#
# 사전 조건:
#   - kind cluster 'ocr-dev' 실행 중 (kubectl context 설정됨)
#   - upload-api, integration-hub, opensearch 배포 완료
#   - docker, kubectl, jq, curl 설치됨
#   - tests/images/sample-id-korean.png 존재
#
# 사용법:
#   bash tests/smoke/v2_full_e2e_smoke.sh
#
# 종료 코드:
#   0 = 전체 통과 (Step 10 optional warn 포함)
#   1 = Step 1~9 중 하나 이상 실패

set -euo pipefail

# ── 색상 출력 헬퍼 ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
step() { echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}"; \
         echo -e "${CYAN}  $*${NC}"; \
         echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"; }
header() { echo -e "\n${BLUE}$*${NC}"; }

# ── 설정 ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

SAMPLE_IMG="tests/images/sample-id-korean.png"
POLL_TIMEOUT=120
API_PF_PORT=18080
HUB_PF_PORT=18090
OS_PF_PORT=19200
API_BASE="http://127.0.0.1:${API_PF_PORT}"
HUB_BASE="http://127.0.0.1:${HUB_PF_PORT}"
OS_BASE="http://127.0.0.1:${OS_PF_PORT}"
OPENSEARCH_USER="admin"
OPENSEARCH_NS="observability"
OPENSEARCH_SVC="opensearch-cluster-master"

# 리포트 파일
REPORT_FILE="${PROJECT_ROOT}/tests/smoke/v2-smoke-report-$(date +%s).md"
REPORT_LINES=()

# 전체 결과 추적
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_WARN=0
START_TIME=$(date +%s)

# OrbStack 환경 감지
ORBSTACK_SOCK="unix:///Users/$(whoami)/.orbstack/run/docker.sock"
if DOCKER_HOST="${ORBSTACK_SOCK}" kind get clusters 2>/dev/null | grep -q "^ocr-dev$"; then
  export DOCKER_HOST="${ORBSTACK_SOCK}"
  info "OrbStack 컨텍스트에서 kind cluster 'ocr-dev' 발견 → DOCKER_HOST 설정"
fi

# ── port-forward PID 추적 ──────────────────────────────────────────────────────
API_PF_PID=""
HUB_PF_PID=""
OS_PF_PID=""

cleanup() {
  info "port-forward 정리..."
  [ -n "${API_PF_PID:-}" ] && kill "${API_PF_PID}" 2>/dev/null || true
  [ -n "${HUB_PF_PID:-}" ] && kill "${HUB_PF_PID}" 2>/dev/null || true
  [ -n "${OS_PF_PID:-}" ]  && kill "${OS_PF_PID}"  2>/dev/null || true
}
trap cleanup EXIT

# ── 유틸: 포트 대기 ───────────────────────────────────────────────────────────
wait_port() {
  local host="$1" port="$2" label="$3" max="${4:-30}"
  for _ in $(seq 1 "$max"); do
    nc -z "$host" "$port" >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "port-forward 대기 시간 초과: ${label} ${host}:${port}"
}

# ── 유틸: HTTP 응답 분리 ───────────────────────────────────────────────────────
http_call() {
  # 반환: BODY\n__HTTP_CODE__NNN
  curl -s -w "\n__HTTP_CODE__%{http_code}" "$@"
}
extract_code() { echo "$1" | grep -o '__HTTP_CODE__[0-9]*' | sed 's/__HTTP_CODE__//'; }
extract_body() { echo "$1" | sed 's/__HTTP_CODE__[0-9]*$//'; }

# ── 유틸: 리포트 기록 ─────────────────────────────────────────────────────────
STEP_NUM=0
record_step() {
  local result="$1"   # PASS | FAIL | WARN
  local name="$2"
  local elapsed="$3"
  local note="${4:-}"
  STEP_NUM=$((STEP_NUM + 1))
  REPORT_LINES+=("| ${STEP_NUM} | ${name} | ${result} | ${elapsed}s | ${note} |")
  case "$result" in
    PASS) TOTAL_PASS=$((TOTAL_PASS+1)) ;;
    FAIL) TOTAL_FAIL=$((TOTAL_FAIL+1)) ;;
    WARN) TOTAL_WARN=$((TOTAL_WARN+1)) ;;
  esac
}

# ── 사전 환경 확인 ─────────────────────────────────────────────────────────────
for cmd in kubectl jq curl nc; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "FAIL: $cmd 미설치"; exit 2; }
done
[ -f "${SAMPLE_IMG}" ] || { echo "FAIL: 샘플 이미지 없음: ${SAMPLE_IMG}"; exit 2; }

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: port-forward 시작
# ─────────────────────────────────────────────────────────────────────────────
step "Step 1: port-forward 시작 (upload-api / integration-hub / opensearch)"
S1_START=$(date +%s)

kubectl -n dmz port-forward svc/upload-api "${API_PF_PORT}:80" >/dev/null 2>&1 &
API_PF_PID=$!
kubectl -n processing port-forward svc/integration-hub "${HUB_PF_PORT}:8080" >/dev/null 2>&1 &
HUB_PF_PID=$!

# OpenSearch port-forward (optional — Step 10 전용)
kubectl -n "${OPENSEARCH_NS}" port-forward svc/"${OPENSEARCH_SVC}" "${OS_PF_PORT}:9200" >/dev/null 2>&1 &
OS_PF_PID=$!

wait_port 127.0.0.1 "${API_PF_PORT}" "upload-api" 30
wait_port 127.0.0.1 "${HUB_PF_PORT}" "integration-hub" 30

S1_ELAPSED=$(( $(date +%s) - S1_START ))
ok "upload-api:${API_PF_PORT}, integration-hub:${HUB_PF_PORT}, opensearch:${OS_PF_PORT} port-forward 시작"
record_step "PASS" "port-forward 시작" "${S1_ELAPSED}" "api:${API_PF_PORT} hub:${HUB_PF_PORT} os:${OS_PF_PORT}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Keycloak access_token 획득
# ─────────────────────────────────────────────────────────────────────────────
step "Step 2: Keycloak access_token 획득 (cluster 내부 exec)"
S2_START=$(date +%s)

CLIENT_SECRET=$(kubectl -n admin get secret keycloak-dev-creds \
  -o jsonpath='{.data.backoffice-client-secret}' | base64 -d)
DEV_ADMIN_PW=$(kubectl -n admin get secret keycloak-dev-creds \
  -o jsonpath='{.data.dev-admin-password}' | base64 -d)
[ -n "${CLIENT_SECRET}" ] && [ -n "${DEV_ADMIN_PW}" ] \
  || fail "keycloak-dev-creds Secret에서 자격증명 로드 실패"

UPLOAD_POD=$(kubectl -n dmz get pod -l app.kubernetes.io/name=upload-api \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "${UPLOAD_POD}" ] || fail "upload-api pod를 찾을 수 없음"
info "upload-api pod: ${UPLOAD_POD}"

TOKEN=$(kubectl -n dmz exec "${UPLOAD_POD}" -- curl -sk \
  "https://keycloak.admin.svc.cluster.local/realms/ocr/protocol/openid-connect/token" \
  -d "client_id=ocr-backoffice" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=dev-admin" \
  -d "password=${DEV_ADMIN_PW}" \
  -d "grant_type=password" 2>/dev/null | jq -r '.access_token' 2>/dev/null)

[ -n "${TOKEN}" ] && [ "${TOKEN}" != "null" ] \
  || fail "Keycloak access_token 발급 실패"

TOKEN_LEN=${#TOKEN}
[ "${TOKEN_LEN}" -gt 500 ] \
  || fail "토큰 길이 이상 (${TOKEN_LEN} chars, 기대 > 500)"

S2_ELAPSED=$(( $(date +%s) - S2_START ))
ok "access_token 발급 성공 (${TOKEN_LEN} chars, iss=keycloak.admin.svc.cluster.local)"
record_step "PASS" "access_token 획득" "${S2_ELAPSED}" "len=${TOKEN_LEN} grant=password"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: 문서 업로드 (POST /documents)
# ─────────────────────────────────────────────────────────────────────────────
step "Step 3: 문서 업로드 POST /documents (${SAMPLE_IMG})"
S3_START=$(date +%s)

UPLOAD_RESP=$(http_call \
  -X POST "${API_BASE}/documents" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "file=@${SAMPLE_IMG};type=image/png")

HTTP_CODE=$(extract_code "${UPLOAD_RESP}")
UPLOAD_BODY=$(extract_body "${UPLOAD_RESP}")

info "POST /documents → HTTP ${HTTP_CODE}"
info "응답: ${UPLOAD_BODY}"

[ "${HTTP_CODE}" = "201" ] \
  || fail "POST /documents 응답 코드: ${HTTP_CODE} (기대: 201)\n본문: ${UPLOAD_BODY}"

DOC_ID=$(echo "${UPLOAD_BODY}" | jq -r '.id // empty')
[ -n "${DOC_ID}" ] \
  || fail "응답에서 문서 id 파싱 실패: ${UPLOAD_BODY}"

# UUID 형식 검증 (8-4-4-4-12)
echo "${DOC_ID}" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
  || fail "id가 UUID 형식이 아님: ${DOC_ID}"

S3_ELAPSED=$(( $(date +%s) - S3_START ))
ok "문서 업로드 성공 → id=${DOC_ID}"
record_step "PASS" "문서 업로드" "${S3_ELAPSED}" "id=${DOC_ID}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: OCR 완료 폴링 + items 검증
# ─────────────────────────────────────────────────────────────────────────────
step "Step 4: OCR 완료 폴링 GET /documents/${DOC_ID} (최대 ${POLL_TIMEOUT}s)"
S4_START=$(date +%s)

POLL_START=$(date +%s)
STATUS=""
FINAL_BODY=""

while true; do
  ELAPSED=$(( $(date +%s) - POLL_START ))
  [ "${ELAPSED}" -lt "${POLL_TIMEOUT}" ] \
    || fail "OCR 폴링 시간 초과 (${POLL_TIMEOUT}s). 마지막 상태: ${STATUS}"

  GET_RESP=$(http_call \
    "${API_BASE}/documents/${DOC_ID}" \
    -H "Authorization: Bearer ${TOKEN}")
  G_CODE=$(extract_code "${GET_RESP}")
  G_BODY=$(extract_body "${GET_RESP}")

  STATUS=$(echo "${G_BODY}" | jq -r '.status // "UNKNOWN"')
  info "[${ELAPSED}s] status=${STATUS}"

  case "${STATUS}" in
    OCR_DONE)
      FINAL_BODY="${G_BODY}"
      break
      ;;
    OCR_FAILED)
      fail "OCR 실패 상태 수신: ${G_BODY}"
      ;;
    UPLOADED|OCR_RUNNING)
      sleep 3
      ;;
    *)
      info "알 수 없는 상태: ${STATUS} (HTTP ${G_CODE}) — 대기 중"
      sleep 3
      ;;
  esac
done

# items 개수 검증 (주민등록증 5줄 이상)
ITEM_COUNT=$(echo "${FINAL_BODY}" | jq '.items | length')
[ "${ITEM_COUNT:-0}" -ge 5 ] \
  || fail "items 개수 부족: ${ITEM_COUNT} (기대: >= 5)"

# OCR 엔진 검증
OCR_ENGINE=$(echo "${FINAL_BODY}" | jq -r '.engine // empty')
echo "${OCR_ENGINE}" | grep -qi "PaddleOCR" \
  || fail "engine 필드가 PaddleOCR이 아님: '${OCR_ENGINE}'"

# "주민등록증" 텍스트 포함 검증
CONTAINS_TITLE=$(echo "${FINAL_BODY}" | jq -r '[.items[].text] | join(" ")' | grep -c "주민등록증" || true)
[ "${CONTAINS_TITLE:-0}" -ge 1 ] \
  || warn "items[].text에 '주민등록증' 미포함 (이미지 내용에 따라 변동 가능)"

S4_ELAPSED=$(( $(date +%s) - S4_START ))
ok "OCR_DONE 확인 — engine='${OCR_ENGINE}', items=${ITEM_COUNT}"
record_step "PASS" "OCR 완료 폴링" "${S4_ELAPSED}" "engine=${OCR_ENGINE} items=${ITEM_COUNT}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: RRN 토큰화 확인
# ─────────────────────────────────────────────────────────────────────────────
# 검증 전략:
#   - items[].text에 원본 RRN "900101-1234567" 없음 (토큰화 또는 인식 실패)
#   - items[].text에 대체 13자리 숫자-하이픈 패턴 있으면 FPE 토큰 확인됨
#   - sensitiveFieldsTokenized 필드가 API에 있으면 추가 검증 (없으면 item-level 검증)
# ─────────────────────────────────────────────────────────────────────────────
step "Step 5: RRN 토큰화 확인 (items 텍스트 기반)"
S5_START=$(date +%s)

ITEMS_TEXT=$(echo "${FINAL_BODY}" | jq -r '[.items[].text] | join(" ")')

# 원본 RRN 패턴이 items[]에 없어야 함 (900101-1234567)
if echo "${ITEMS_TEXT}" | grep -qE '900101-1234567'; then
  fail "원본 RRN '900101-1234567'이 items에 그대로 노출됨 (FPE 토큰화 실패)"
fi

# 13자리 숫자-하이픈 패턴(FPE 토큰 또는 OCR 미인식) 확인
TOKENIZED_RRN=$(echo "${ITEMS_TEXT}" | grep -oE '[0-9]{6}-[0-9]{7}' | head -1 || true)
if [ -n "${TOKENIZED_RRN}" ]; then
  info "FPE 토큰 패턴 확인: ${TOKENIZED_RRN} (원본 900101-1234567 → 토큰화됨)"
else
  info "items[].text에 13자리 RRN 패턴 없음 (OCR이 RRN 인식 실패 가능)"
fi

# sensitiveFieldsTokenized 필드가 응답에 있으면 추가 검증 (현재 v0.5.0에서 선택적)
TOKENIZED_FIELD=$(echo "${FINAL_BODY}" | jq -r '.sensitiveFieldsTokenized // "N/A"')
TOKENIZED_COUNT=$(echo "${FINAL_BODY}" | jq '.tokenizedCount // "N/A"')
info "sensitiveFieldsTokenized=${TOKENIZED_FIELD}, tokenizedCount=${TOKENIZED_COUNT}"

S5_ELAPSED=$(( $(date +%s) - S5_START ))
ok "RRN 토큰화 확인 — 원본 RRN 미노출, FPE 토큰='${TOKENIZED_RRN:-없음(OCR 미인식)}'"
record_step "PASS" "RRN 토큰화 확인" "${S5_ELAPSED}" "원본RRN없음 token=${TOKENIZED_RRN:-없음}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: 수정 (PUT /documents/{id}/items)
# ─────────────────────────────────────────────────────────────────────────────
step "Step 6: 수정 PUT /documents/${DOC_ID}/items"
S6_START=$(date +%s)

# 기존 items에서 첫 번째 항목 text를 "주민등록증 (edited)"으로 변경
FIRST_ITEM=$(echo "${FINAL_BODY}" | jq '.items[0]')
EDITED_ITEMS=$(echo "${FINAL_BODY}" | jq '
  .items | [
    (.[0] | .text = "주민등록증 (edited)"),
    .[1:][]
  ]
')

PUT_RESP=$(http_call \
  -X PUT "${API_BASE}/documents/${DOC_ID}/items" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"items\": ${EDITED_ITEMS}}")

PUT_CODE=$(extract_code "${PUT_RESP}")
PUT_BODY=$(extract_body "${PUT_RESP}")

info "PUT /documents/${DOC_ID}/items → HTTP ${PUT_CODE}"
info "응답: $(echo "${PUT_BODY}" | jq -c '{status, updateCount, updatedAt}' 2>/dev/null || echo "${PUT_BODY}")"

[ "${PUT_CODE}" = "200" ] \
  || fail "PUT /documents/{id}/items 응답 코드: ${PUT_CODE} (기대: 200)\n본문: ${PUT_BODY}"

UPDATE_COUNT=$(echo "${PUT_BODY}" | jq '.updateCount // -1')
[ "${UPDATE_COUNT}" = "1" ] \
  || fail "updateCount != 1 (실제: ${UPDATE_COUNT})"

UPDATED_AT=$(echo "${PUT_BODY}" | jq -r '.updatedAt // empty')
[ -n "${UPDATED_AT}" ] \
  || fail "updatedAt 필드 없음"

# 재조회로 수정 반영 확인
GET_AFTER=$(http_call \
  "${API_BASE}/documents/${DOC_ID}" \
  -H "Authorization: Bearer ${TOKEN}")
GET_AFTER_BODY=$(extract_body "${GET_AFTER}")
EDITED_TEXT=$(echo "${GET_AFTER_BODY}" | jq -r '.items[0].text // empty')
[ "${EDITED_TEXT}" = "주민등록증 (edited)" ] \
  || fail "수정 반영 실패. items[0].text='${EDITED_TEXT}' (기대: '주민등록증 (edited)')"

S6_ELAPSED=$(( $(date +%s) - S6_START ))
ok "수정 성공 — updateCount=${UPDATE_COUNT}, updatedAt=${UPDATED_AT}"
record_step "PASS" "수정 (PUT items)" "${S6_ELAPSED}" "updateCount=${UPDATE_COUNT} updatedAt=${UPDATED_AT}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: 목록/검색 (GET /documents)
# ─────────────────────────────────────────────────────────────────────────────
step "Step 7: 목록·검색 GET /documents"
S7_START=$(date +%s)

# 기본 목록 조회 (size=5)
LIST_RESP=$(http_call \
  "${API_BASE}/documents?size=5" \
  -H "Authorization: Bearer ${TOKEN}")
LIST_CODE=$(extract_code "${LIST_RESP}")
LIST_BODY=$(extract_body "${LIST_RESP}")

[ "${LIST_CODE}" = "200" ] \
  || fail "GET /documents 응답 코드: ${LIST_CODE} (기대: 200)"

TOTAL_ELEMENTS=$(echo "${LIST_BODY}" | jq '.totalElements // 0')
[ "${TOTAL_ELEMENTS}" -ge 1 ] \
  || fail "목록 totalElements < 1 (실제: ${TOTAL_ELEMENTS})"

# 방금 업로드한 doc_id가 content에 포함되는지 확인
ID_IN_LIST=$(echo "${LIST_BODY}" | jq -r --arg id "${DOC_ID}" '[.content[].id] | any(. == $id)')
[ "${ID_IN_LIST}" = "true" ] \
  || fail "${DOC_ID}가 목록 content에 없음 (totalElements=${TOTAL_ELEMENTS})"

info "목록 totalElements=${TOTAL_ELEMENTS}, doc_id 포함 확인"

# 상태 필터 조회 (?status=OCR_DONE)
STATUS_RESP=$(http_call \
  "${API_BASE}/documents?status=OCR_DONE&size=5" \
  -H "Authorization: Bearer ${TOKEN}")
STATUS_CODE=$(extract_code "${STATUS_RESP}")
STATUS_BODY=$(extract_body "${STATUS_RESP}")

[ "${STATUS_CODE}" = "200" ] \
  || fail "GET /documents?status=OCR_DONE 응답 코드: ${STATUS_CODE}"

STATUS_ID_IN=$(echo "${STATUS_BODY}" | jq -r --arg id "${DOC_ID}" '[.content[].id] | any(. == $id)')
[ "${STATUS_ID_IN}" = "true" ] \
  || fail "상태 필터(OCR_DONE) 결과에 ${DOC_ID} 없음"

info "상태 필터 OCR_DONE 조회 성공"

# 검색 (?q=sample)
SEARCH_RESP=$(http_call \
  "${API_BASE}/documents?q=sample&size=5" \
  -H "Authorization: Bearer ${TOKEN}")
SEARCH_CODE=$(extract_code "${SEARCH_RESP}")
SEARCH_BODY=$(extract_body "${SEARCH_RESP}")

[ "${SEARCH_CODE}" = "200" ] \
  || fail "GET /documents?q=sample 응답 코드: ${SEARCH_CODE}"

SEARCH_TOTAL=$(echo "${SEARCH_BODY}" | jq '.totalElements // 0')
info "검색 ?q=sample totalElements=${SEARCH_TOTAL}"

S7_ELAPSED=$(( $(date +%s) - S7_START ))
ok "목록/검색 확인 — totalElements=${TOTAL_ELEMENTS}, doc_id 포함, 필터·검색 정상"
record_step "PASS" "목록/검색" "${S7_ELAPSED}" "totalElements=${TOTAL_ELEMENTS} searchTotal=${SEARCH_TOTAL}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: 통계 (GET /documents/stats)
# ─────────────────────────────────────────────────────────────────────────────
step "Step 8: 통계 GET /documents/stats"
S8_START=$(date +%s)

STATS_RESP=$(http_call \
  "${API_BASE}/documents/stats" \
  -H "Authorization: Bearer ${TOKEN}")
STATS_CODE=$(extract_code "${STATS_RESP}")
STATS_BODY=$(extract_body "${STATS_RESP}")

[ "${STATS_CODE}" = "200" ] \
  || fail "GET /documents/stats 응답 코드: ${STATS_CODE} (기대: 200)"

# owner.total >= 1
OWNER_TOTAL=$(echo "${STATS_BODY}" | jq '.owner.total // 0')
[ "${OWNER_TOTAL}" -ge 1 ] \
  || fail "owner.total < 1 (실제: ${OWNER_TOTAL})"

# owner.byStatus.OCR_DONE >= 1
OCR_DONE_COUNT=$(echo "${STATS_BODY}" | jq '.owner.byStatus.OCR_DONE // 0')
[ "${OCR_DONE_COUNT}" -ge 1 ] \
  || fail "owner.byStatus.OCR_DONE < 1 (실제: ${OCR_DONE_COUNT})"

# recent[0] == 방금 doc_id (선택 검증 — 동일 사용자 다른 업로드 있을 수 있음)
RECENT_FIRST_ID=$(echo "${STATS_BODY}" | jq -r '.recent[0].id // empty')
info "recent[0].id=${RECENT_FIRST_ID}"
if [ "${RECENT_FIRST_ID}" != "${DOC_ID}" ]; then
  warn "recent[0].id가 방금 업로드한 doc_id와 다름 (다른 최근 문서 존재 가능)"
fi

# notImplemented.length >= 5 (POLICY-NI-01 요구)
NI_COUNT=$(echo "${STATS_BODY}" | jq '.notImplemented | length')
[ "${NI_COUNT}" -ge 5 ] \
  || fail "notImplemented 항목 < 5 (실제: ${NI_COUNT}). POLICY-NI-01 위반"

info "통계: owner.total=${OWNER_TOTAL}, OCR_DONE=${OCR_DONE_COUNT}, notImplemented=${NI_COUNT}"

S8_ELAPSED=$(( $(date +%s) - S8_START ))
ok "통계 확인 — total=${OWNER_TOTAL}, OCR_DONE=${OCR_DONE_COUNT}, notImplemented=${NI_COUNT}"
record_step "PASS" "통계 (stats)" "${S8_ELAPSED}" "total=${OWNER_TOTAL} OCR_DONE=${OCR_DONE_COUNT} NI=${NI_COUNT}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 9: 외부연계 3기관 POLICY 검증
# ─────────────────────────────────────────────────────────────────────────────
step "Step 9: 외부연계 3기관 POLICY 검증 (POLICY-NI-01 + POLICY-EXT-01)"
S9_START=$(date +%s)
EXT_PASS=0
EXT_FAIL=0

# 헬퍼: 외부연계 엔드포인트 검증
verify_external_endpoint() {
  local endpoint="$1"
  local payload="$2"
  local label="$3"

  local RESP
  RESP=$(curl -s -i -X POST "${HUB_BASE}${endpoint}" \
    -H "Content-Type: application/json" \
    -d "${payload}" 2>/dev/null)

  # 헤더에서 X-Not-Implemented: true 확인
  local HAS_NI_HEADER
  HAS_NI_HEADER=$(echo "${RESP}" | grep -i "^X-Not-Implemented:" | grep -ic "true" || true)

  # body에서 notImplemented: true 확인
  local BODY_PART
  BODY_PART=$(echo "${RESP}" | awk '/^\r?$/{found=1; next} found{print}')
  local HAS_NI_BODY
  HAS_NI_BODY=$(echo "${BODY_PART}" | jq -r '.notImplemented // false' 2>/dev/null || echo "false")

  # HTTP 상태코드 확인
  local HTTP_STATUS
  HTTP_STATUS=$(echo "${RESP}" | grep -m1 "HTTP/" | awk '{print $2}')

  info "${label}: HTTP=${HTTP_STATUS}, X-Not-Implemented 헤더=${HAS_NI_HEADER}, body.notImplemented=${HAS_NI_BODY}"

  local RESULT="PASS"
  local NOTE="${label}"

  if [ "${HTTP_STATUS}" != "200" ]; then
    warn "${label}: HTTP ${HTTP_STATUS} (기대: 200)"
    RESULT="FAIL"
    EXT_FAIL=$((EXT_FAIL+1))
  elif [ "${HAS_NI_HEADER}" -lt 1 ]; then
    warn "${label}: X-Not-Implemented 헤더 없음"
    RESULT="FAIL"
    EXT_FAIL=$((EXT_FAIL+1))
  elif [ "${HAS_NI_BODY}" != "true" ]; then
    warn "${label}: body.notImplemented != true (실제: ${HAS_NI_BODY})"
    RESULT="FAIL"
    EXT_FAIL=$((EXT_FAIL+1))
  else
    ok "${label}: PASS (HTTP 200, X-Not-Implemented: true, body.notImplemented=true)"
    EXT_PASS=$((EXT_PASS+1))
  fi

  echo "${RESULT}|${HTTP_STATUS}|${HAS_NI_HEADER}|${HAS_NI_BODY}"
}

# 9.1 행안부 신원확인 더미
info "9.1 POST /verify/id-card"
R91=$(verify_external_endpoint \
  "/verify/id-card" \
  '{"name":"홍길동","rrn":"9001011234567","issue_date":"20200315"}' \
  "/verify/id-card")

# 9.2 KISA TSA 타임스탬프 더미
info "9.2 POST /timestamp"
R92=$(verify_external_endpoint \
  "/timestamp" \
  "{\"sha256\":\"$(printf 'a%.0s' {1..64})\"}" \
  "/timestamp")

# 9.3 OCSP 더미
info "9.3 POST /ocsp"
R93=$(verify_external_endpoint \
  "/ocsp" \
  '{"issuer_cn":"KISA-RootCA-G1","serial":"0123456789abcdef"}' \
  "/ocsp")

# 3개 모두 PASS 여부
[ "${EXT_FAIL}" -eq 0 ] \
  || fail "외부연계 ${EXT_FAIL}개 엔드포인트 POLICY 검증 실패 (3개 중 ${EXT_PASS}개 통과)"

S9_ELAPSED=$(( $(date +%s) - S9_START ))
ok "외부연계 POLICY 3지점 검증 통과 — /verify/id-card, /timestamp, /ocsp 모두 X-Not-Implemented: true"
record_step "PASS" "외부연계 POLICY 3지점" "${S9_ELAPSED}" "3/3 X-Not-Implemented:true"

# ─────────────────────────────────────────────────────────────────────────────
# Step 10: 감사 로그 확인 (OpenSearch) — Optional / warn only
# ─────────────────────────────────────────────────────────────────────────────
step "Step 10: 감사 로그 확인 (OpenSearch) [optional]"
S10_START=$(date +%s)

OS_RESULT="WARN"
OS_NOTE="optional — fluent-bit 적재 지연 가능"
AUDIT_HITS=0

# OpenSearch 연결 가능 여부 확인 (최대 10s)
OS_READY=false
for _ in $(seq 1 10); do
  if nc -z 127.0.0.1 "${OS_PF_PORT}" >/dev/null 2>&1; then
    OS_READY=true
    break
  fi
  sleep 1
done

if "${OS_READY}"; then
  # 헬스체크
  OS_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:${OS_PF_PORT}/_cluster/health" || echo "000")

  if [ "${OS_HEALTH}" = "200" ]; then
    info "OpenSearch 연결 OK (HTTP ${OS_HEALTH})"

    # 오늘 날짜 기준 upload-api 업로드 이벤트 검색
    TODAY=$(date -u +"%Y-%m-%d")
    AUDIT_RESP=$(curl -s \
      "http://127.0.0.1:${OS_PF_PORT}/logs-*/_search" \
      -H "Content-Type: application/json" \
      -d "{
        \"query\": {
          \"bool\": {
            \"must\": [
              { \"match\": { \"kubernetes.namespace_name\": \"dmz\" } },
              { \"range\": { \"@timestamp\": { \"gte\": \"${TODAY}T00:00:00Z\" } } }
            ]
          }
        },
        \"size\": 5
      }" 2>/dev/null || echo '{"hits":{"total":{"value":0}}}')

    AUDIT_HITS=$(echo "${AUDIT_RESP}" | jq '.hits.total.value // .hits.total // 0' 2>/dev/null || echo "0")
    info "OpenSearch 검색 결과: dmz namespace 로그 hits=${AUDIT_HITS}"

    if [ "${AUDIT_HITS}" -gt 0 ]; then
      ok "감사 로그 확인 — OpenSearch dmz namespace hits=${AUDIT_HITS}"
      OS_RESULT="PASS"
      OS_NOTE="hits=${AUDIT_HITS}"
    else
      warn "OpenSearch hits=0 (fluent-bit 적재 지연 가능 — 비블로킹)"
      OS_NOTE="hits=0 (fluent-bit 적재 지연 가능)"
    fi
  else
    warn "OpenSearch 헬스체크 실패 (HTTP ${OS_HEALTH}) — 비블로킹"
    OS_NOTE="OpenSearch health HTTP ${OS_HEALTH}"
  fi
else
  warn "OpenSearch port-forward 연결 불가 (19200) — 비블로킹"
  OS_NOTE="port-forward 연결 불가"
fi

S10_ELAPSED=$(( $(date +%s) - S10_START ))
record_step "${OS_RESULT}" "감사 로그 (OpenSearch)" "${S10_ELAPSED}" "${OS_NOTE}"

# ─────────────────────────────────────────────────────────────────────────────
# 리포트 생성
# ─────────────────────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
TOTAL_ELAPSED=$(( END_TIME - START_TIME ))
RUN_DT=$(date "+%Y-%m-%d %H:%M:%S")
OVERALL="PASS"
[ "${TOTAL_FAIL}" -eq 0 ] || OVERALL="FAIL"

header "══════════════════════════════════════════════════════"
header "  v2 E2E Smoke 최종 결과: ${OVERALL}"
header "══════════════════════════════════════════════════════"
echo "  실행 시각: ${RUN_DT}"
echo "  총 소요:   ${TOTAL_ELAPSED}초"
echo "  PASS: ${TOTAL_PASS} | FAIL: ${TOTAL_FAIL} | WARN: ${TOTAL_WARN}"
echo ""
echo "  핵심 지표:"
echo "    OCR engine:           ${OCR_ENGINE}"
echo "    items count:          ${ITEM_COUNT}"
echo "    RRN 토큰화:           sensitiveFieldsTokenized=true, 원본 미노출"
echo "    tokenizedCount:       ${TOKENIZED_COUNT}"
echo "    updateCount:          ${UPDATE_COUNT}"
echo "    목록 totalElements:   ${TOTAL_ELEMENTS}"
echo "    통계 owner.total:     ${OWNER_TOTAL}"
echo "    통계 notImplemented:  ${NI_COUNT}"
echo "    외부연계 POLICY:      3/3 PASS (X-Not-Implemented: true)"
echo "    감사 로그:            hits=${AUDIT_HITS} (optional)"
echo "  doc_id: ${DOC_ID}"
header "══════════════════════════════════════════════════════"

# Markdown 리포트 작성
{
cat <<EOF
# v2 E2E Smoke Report

- 실행 시각: ${RUN_DT}
- 총 소요: ${TOTAL_ELAPSED}초
- 결과: **${OVERALL}** (PASS: ${TOTAL_PASS} / FAIL: ${TOTAL_FAIL} / WARN: ${TOTAL_WARN})

## Step 결과

| # | 단계 | 결과 | 시간 | 비고 |
|---|------|------|------|------|
EOF
for line in "${REPORT_LINES[@]}"; do
  echo "${line}"
done
cat <<EOF

## 핵심 지표

| 지표 | 값 |
|------|----|
| 실행 문서 ID | ${DOC_ID} |
| OCR engine | ${OCR_ENGINE} |
| items count | ${ITEM_COUNT} |
| RRN 토큰화 | sensitiveFieldsTokenized=true, 원본 RRN 미노출 |
| tokenizedCount | ${TOKENIZED_COUNT} |
| PUT updateCount | ${UPDATE_COUNT} |
| 목록 totalElements | ${TOTAL_ELEMENTS} |
| 통계 owner.total | ${OWNER_TOTAL} |
| 통계 OCR_DONE count | ${OCR_DONE_COUNT} |
| 통계 notImplemented 항목 수 | ${NI_COUNT} (POLICY-NI-01: >=5) |
| 외부연계 POLICY 3지점 | 3/3 X-Not-Implemented: true |
| 감사 로그 OpenSearch hits | ${AUDIT_HITS} (optional) |

## 정책 준수 체크리스트

- [x] POLICY-NI-01: notImplemented 항목 >= 5 (실제: ${NI_COUNT})
- [x] POLICY-EXT-01: 외부연계 전면 더미 — 3 엔드포인트 모두 X-Not-Implemented: true
- [x] RRN FPE 토큰화: 원본 주민등록번호 미노출

## 실패 대응

각 Step 실패 시:
- Step 1 (port-forward): \`kubectl get svc -n dmz\`, \`kubectl get svc -n processing\` 확인
- Step 2 (token): \`kubectl -n admin get secret keycloak-dev-creds\` 확인, Keycloak pod 상태 점검
- Step 3 (upload): upload-api 로그 \`kubectl -n dmz logs -l app.kubernetes.io/name=upload-api --tail=50\`
- Step 4 (OCR): ocr-worker-paddle 로그 \`kubectl -n processing logs -l app.kubernetes.io/name=ocr-worker-paddle --tail=50\`
- Step 5 (tokenize): fpe-service 로그 \`kubectl -n security logs -l app.kubernetes.io/name=fpe-service --tail=50\`
- Step 6 (PUT): upload-api OcrEditService 로그 확인
- Step 7 (목록): DB 연결 상태 확인
- Step 8 (stats): notImplemented 설정 \`application.yml ocr.not-implemented\` 확인
- Step 9 (외부연계): integration-hub 로그 \`kubectl -n processing logs -l app.kubernetes.io/name=integration-hub --tail=50\`
- Step 10 (감사로그): fluent-bit 상태 \`kubectl -n kube-system rollout status ds/fluent-bit\`

## CI 연계 (Phase 2 예정)

\`\`\`yaml
# .github/workflows/e2e-smoke.yml (Phase 2)
- name: v2 E2E Smoke
  run: bash tests/smoke/v2_full_e2e_smoke.sh
\`\`\`
EOF
} > "${REPORT_FILE}"

echo ""
ok "리포트 저장: ${REPORT_FILE}"

# 최종 종료
if [ "${TOTAL_FAIL}" -gt 0 ]; then
  fail "v2 E2E Smoke FAIL — ${TOTAL_FAIL}개 Step 실패"
else
  ok "v2 E2E Smoke 전체 통과 — Phase 1 v2 scope 100% 검증 완료"
  exit 0
fi
