#!/usr/bin/env bash
# upload_api_e2e_smoke.sh
# B1-T5 end-to-end smoke:
#   (a) CA Secret → dmz ns 복사
#   (b) Docker build + kind load
#   (c) kubectl apply manifests → Deployment Ready 대기
#   (d) Keycloak port-forward → access_token 획득 (dev-admin, password grant)
#   (e) upload-api port-forward → POST /documents (sample PNG) → 201 확인
#   (f) GET /documents/{id} 폴링 → OCR_DONE + items≥1 확인
#   (g) 정리
#
# 사전 조건:
#   - B1-T1 smoke 완료 (dmz ns에 upload-api-db-creds Secret 존재)
#   - kind cluster 'ocr-dev' 실행 중
#   - docker, kubectl, jq, curl 설치됨
#
# 사용법:
#   bash tests/smoke/upload_api_e2e_smoke.sh
#
# 종료 코드:
#   0 = 전체 통과, 1 = 검증 실패, 2 = 환경 오류

set -euo pipefail

# ── 색상 출력 헬퍼 ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
step() { echo -e "\n${CYAN}══ $* ${NC}"; }

# ── 환경 확인 ─────────────────────────────────────────────────────────────────
for cmd in docker kubectl jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "FAIL: $cmd 미설치"; exit 2; }
done

# 작업 디렉터리: 프로젝트 루트
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

KIND_CLUSTER="ocr-dev"
IMAGE_NAME="upload-api:v0.1.0"
MANIFEST_DIR="infra/manifests/upload-api"
SAMPLE_IMAGE="tests/images/sample-id-korean.png"
POLL_TIMEOUT=120   # OCR 완료 대기 최대 초
KC_PF_PORT=18443
API_PF_PORT=18080

# OrbStack에서 kind가 실행되는 경우 DOCKER_HOST를 자동 감지
# kind cluster가 OrbStack 컨텍스트에 존재하면 해당 소켓을 사용
ORBSTACK_SOCK="unix:///Users/jimmy/.orbstack/run/docker.sock"
if DOCKER_HOST="${ORBSTACK_SOCK}" kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
  export DOCKER_HOST="${ORBSTACK_SOCK}"
  info "OrbStack 컨텍스트에서 kind cluster '${KIND_CLUSTER}' 발견 → DOCKER_HOST 설정"
fi

# port-forward PID 추적
KC_PF_PID=""
API_PF_PID=""

cleanup() {
  info "port-forward 정리..."
  [ -n "${KC_PF_PID:-}" ] && kill "${KC_PF_PID}" 2>/dev/null || true
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

# ── Step (a): ocr-internal CA → dmz ns Secret 복사 ───────────────────────────
step "Step (a): ocr-internal CA → dmz ns"
CA_B64=$(kubectl -n security get secret ocr-internal-root-ca-key-pair \
  -o jsonpath='{.data.ca\.crt}')
[ -n "${CA_B64}" ] || fail "security ns에서 CA 조회 실패"

kubectl create secret generic ocr-internal-ca \
  --namespace dmz \
  --from-literal="ca.crt=$(echo "${CA_B64}" | base64 -d)" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "dmz/ocr-internal-ca Secret 준비 완료"

# ── Step (b): Docker build + kind load ───────────────────────────────────────
step "Step (b): Docker build + kind load"
info "docker build -t ${IMAGE_NAME} services/upload-api/"
docker build -t "${IMAGE_NAME}" services/upload-api/
ok "Docker 이미지 빌드 완료: ${IMAGE_NAME}"

info "kind load docker-image ${IMAGE_NAME} --name ${KIND_CLUSTER}"
kind load docker-image "${IMAGE_NAME}" --name "${KIND_CLUSTER}"
ok "kind 클러스터에 이미지 로드 완료"

# ── Step (c): 매니페스트 apply → Deployment Ready 대기 ───────────────────────
# dmz-db-bootstrap.yaml은 B1-T1 소관 — 재apply 시 Job이 재실행되어 DB 비밀번호가
# 변경되고 upload-api가 인증 실패하므로 제외.
step "Step (c): manifests apply + Deployment Ready"
for f in "${MANIFEST_DIR}"/*.yaml; do
  case "$(basename "$f")" in
    dmz-db-bootstrap.yaml) info "스킵: $f (B1-T1 소관, Job 재실행 방지)"; continue ;;
  esac
  kubectl apply -f "$f"
done
ok "매니페스트 apply 완료 (dmz-db-bootstrap.yaml 제외)"

info "Deployment 'upload-api' Ready 대기 (최대 180s)..."
kubectl -n dmz rollout status deployment/upload-api --timeout=180s
ok "upload-api Deployment Ready"

# ── Step (d): Keycloak token 획득 ────────────────────────────────────────────
# 중요: token은 cluster 내부(upload-api pod)에서 발급받아야 iss claim이
# "https://keycloak.admin.svc.cluster.local/realms/ocr" (포트 없음)으로 발급된다.
# 외부 port-forward에서 발급 시 iss에 포트번호가 포함되어 upload-api 검증에 실패.
step "Step (d): Keycloak access_token 획득 (cluster 내부)"

# keycloak-dev-creds에서 자격증명 로드
CLIENT_SECRET=$(kubectl -n admin get secret keycloak-dev-creds \
  -o jsonpath='{.data.backoffice-client-secret}' | base64 -d)
DEV_ADMIN_PW=$(kubectl -n admin get secret keycloak-dev-creds \
  -o jsonpath='{.data.dev-admin-password}' | base64 -d)
[ -n "${CLIENT_SECRET}" ] && [ -n "${DEV_ADMIN_PW}" ] \
  || fail "keycloak-dev-creds Secret에서 자격증명 로드 실패"

# upload-api pod를 통해 Keycloak에서 token 발급 (iss claim이 svc DNS로 발급됨)
UPLOAD_POD_FOR_TOKEN=$(kubectl -n dmz get pod -l app.kubernetes.io/name=upload-api \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "${UPLOAD_POD_FOR_TOKEN}" ] || fail "upload-api pod를 찾을 수 없음"

TOKEN=$(kubectl -n dmz exec "${UPLOAD_POD_FOR_TOKEN}" -- curl -sk \
  "https://keycloak.admin.svc.cluster.local/realms/ocr/protocol/openid-connect/token" \
  -d "client_id=ocr-backoffice" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "username=dev-admin" \
  -d "password=${DEV_ADMIN_PW}" \
  -d "grant_type=password" 2>/dev/null | jq -r '.access_token' 2>/dev/null)

[ -n "${TOKEN}" ] && [ "${TOKEN}" != "null" ] \
  || fail "Keycloak access_token 발급 실패 (cluster 내부 발급)"
ok "access_token 발급 성공 (${#TOKEN} chars, iss=keycloak.admin.svc.cluster.local)"

# ── Step (e): POST /documents ─────────────────────────────────────────────────
step "Step (e): POST /documents (${SAMPLE_IMAGE})"
[ -f "${SAMPLE_IMAGE}" ] || fail "샘플 이미지 없음: ${SAMPLE_IMAGE}"

# upload-api port-forward
kubectl -n dmz port-forward svc/upload-api "${API_PF_PORT}:80" >/dev/null 2>&1 &
API_PF_PID=$!
wait_port 127.0.0.1 "${API_PF_PORT}" "upload-api" 30

API_BASE="http://127.0.0.1:${API_PF_PORT}"

UPLOAD_RESP=$(curl -s -w "\n__HTTP_CODE__%{http_code}" \
  -X POST "${API_BASE}/documents" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "file=@${SAMPLE_IMAGE};type=image/png")

HTTP_CODE=$(echo "${UPLOAD_RESP}" | grep -o '__HTTP_CODE__[0-9]*' | sed 's/__HTTP_CODE__//')
BODY=$(echo "${UPLOAD_RESP}" | sed 's/__HTTP_CODE__[0-9]*$//')

info "POST /documents → HTTP ${HTTP_CODE}"
info "응답 본문: ${BODY}"

[ "${HTTP_CODE}" = "201" ] || fail "POST /documents 응답 코드: ${HTTP_CODE} (기대: 201)\n본문: ${BODY}"

DOC_ID=$(echo "${BODY}" | jq -r '.id')
[ -n "${DOC_ID}" ] && [ "${DOC_ID}" != "null" ] \
  || fail "응답에서 문서 id 파싱 실패: ${BODY}"
ok "문서 업로드 성공 → id=${DOC_ID}"

# ── Step (f): GET /documents/{id} 폴링 → OCR_DONE ───────────────────────────
step "Step (f): GET /documents/${DOC_ID} 폴링 (최대 ${POLL_TIMEOUT}s)"

START=$(date +%s)
STATUS=""
FINAL_BODY=""

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))
  [ "${ELAPSED}" -lt "${POLL_TIMEOUT}" ] || fail "폴링 시간 초과 (${POLL_TIMEOUT}s). 마지막 상태: ${STATUS}"

  GET_RESP=$(curl -s -w "\n__HTTP_CODE__%{http_code}" \
    "${API_BASE}/documents/${DOC_ID}" \
    -H "Authorization: Bearer ${TOKEN}")
  G_CODE=$(echo "${GET_RESP}" | grep -o '__HTTP_CODE__[0-9]*' | sed 's/__HTTP_CODE__//')
  G_BODY=$(echo "${GET_RESP}" | sed 's/__HTTP_CODE__[0-9]*$//')

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
      info "알 수 없는 상태: ${STATUS} (HTTP ${G_CODE}) — 계속 대기"
      sleep 3
      ;;
  esac
done

ITEM_COUNT=$(echo "${FINAL_BODY}" | jq '.items | length')
[ "${ITEM_COUNT:-0}" -ge 1 ] \
  || fail "OCR_DONE이지만 items가 비어 있음: ${FINAL_BODY}"

ok "OCR_DONE 확인 — items=${ITEM_COUNT}"
echo ""
echo "── 샘플 OCR 결과 (최대 3건) ─────────────────────────────────"
echo "${FINAL_BODY}" | jq '{
  id,
  status,
  engine,
  langs,
  item_count: (.items | length),
  first_items: (.items[:3] | map({text, confidence}))
}'
echo "─────────────────────────────────────────────────────────────"

# ── 완료 ─────────────────────────────────────────────────────────────────────
echo ""
ok "B1-T5 e2e smoke 전체 통과"
echo ""
echo "Phase 1 carry-overs (이번 smoke 중 확인된 사항):"
echo "  - dmz → processing 트래픽은 NP로 허용되나 mTLS(상호 TLS) 미적용 (Phase 1 Cilium mTLS 대상)"
echo "  - dev-admin 비밀번호가 keycloak-dev-creds Secret에 평문 저장 (Phase 1 sealed-secrets/ExternalSecrets 강화 예정)"
echo "  - S3 access-key/secret-key가 Deployment env에 평문 (Phase 1 Secret으로 분리 예정)"
echo "  - ocr-internal-ca Secret을 스크립트로 수동 복사 중 (Phase 1 cert-manager ClusterSecretStore 또는 Reflector로 자동화 예정)"
