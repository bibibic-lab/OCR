#!/usr/bin/env bash
# ============================================================
# logs_smoke.sh — Fluentbit → OpenSearch 로그 수집 검증
#
# 목적:
#   1. Fluentbit DaemonSet이 모든 노드에서 Ready 상태인지 확인
#   2. 최근 30초 내의 로그가 OpenSearch에 인덱싱됐는지 검증
#      (kubectl exec 출력은 container log file에 기록되지 않아
#       processing/ocr-worker의 정기 healthcheck 로그를 활용)
#
# 전제조건:
#   - kubectl 설정 완료 (올바른 kubeconfig)
#   - python3 설치 (JSON 파싱)
#   - curl 설치
#
# 실행 방법:
#   chmod +x tests/smoke/logs_smoke.sh
#   ./tests/smoke/logs_smoke.sh
# ============================================================
set -euo pipefail

FLUENTBIT_NS="kube-system"
FLUENTBIT_DS="fluent-bit"
OPENSEARCH_SVC="opensearch-cluster-master"
OPENSEARCH_NS="observability"
OPENSEARCH_PORT="9200"
LOCAL_PORT="19200"
PF_PID=""

# ── 색상 출력 헬퍼 ──────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${YELLOW}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
fail()    { echo -e "${RED}[FAIL]${NC} $*"; }

cleanup() {
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null || true
    info "port-forward 종료 (PID=$PF_PID)"
  fi
}
trap cleanup EXIT

# ── Step 1: Fluentbit DaemonSet Ready 확인 ──────────────────
info "Step 1: Fluentbit DaemonSet rollout 확인 (namespace=$FLUENTBIT_NS)..."
kubectl -n "$FLUENTBIT_NS" rollout status ds/"$FLUENTBIT_DS" --timeout=120s
DESIRED=$(kubectl -n "$FLUENTBIT_NS" get ds "$FLUENTBIT_DS" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
READY=$(kubectl -n "$FLUENTBIT_NS" get ds "$FLUENTBIT_DS" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
success "Fluentbit DS: $READY/$DESIRED 노드 Ready"

if [ "$READY" -lt "$DESIRED" ]; then
  fail "일부 노드에서 Fluentbit 미준비 ($READY/$DESIRED)"
  exit 1
fi

# ── Step 2: OpenSearch port-forward ───────────────────────
info "Step 2: OpenSearch port-forward 시작 (localhost:$LOCAL_PORT)..."
kubectl -n "$OPENSEARCH_NS" port-forward svc/"$OPENSEARCH_SVC" "${LOCAL_PORT}:${OPENSEARCH_PORT}" &>/dev/null &
PF_PID=$!
sleep 3

# 헬스체크
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${LOCAL_PORT}/_cluster/health" || echo "000")
if [[ "$HTTP_STATUS" != "200" ]]; then
  fail "OpenSearch 헬스체크 실패 (HTTP $HTTP_STATUS). port-forward 또는 OpenSearch 상태 확인 필요."
  exit 1
fi
success "  OpenSearch 연결 OK (HTTP $HTTP_STATUS)"

# ── Step 3: 인덱스 존재 확인 ──────────────────────────────
info "Step 3: logs-* 인덱스 확인..."
INDEX_LIST=$(curl -s "http://localhost:${LOCAL_PORT}/_cat/indices/logs-*?v")
echo "$INDEX_LIST"

DOC_COUNT=$(echo "$INDEX_LIST" | awk 'NR>1 {sum += $7} END {print sum+0}')
if [ "${DOC_COUNT:-0}" -eq 0 ]; then
  fail "logs-* 인덱스가 없거나 도큐먼트가 없음. Fluentbit 로그를 확인하세요."
  exit 1
fi
success "  총 ${DOC_COUNT}개 도큐먼트 인덱싱됨"

# ── Step 4: 최근 로그 실시간 수집 확인 ──────────────────────
info "Step 4: 최근 60초 내 로그 수집 확인..."
# 현재 시각 기준 60초 전 ISO8601 타임스탬프
SINCE=$(python3 -c "
from datetime import datetime, timedelta, timezone
dt = datetime.now(timezone.utc) - timedelta(seconds=60)
print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
")
info "  since: $SINCE"

RECENT_HITS=$(curl -s -X GET "http://localhost:${LOCAL_PORT}/logs-*/_search" \
  -H 'Content-Type: application/json' \
  -d "{
    \"query\": {
      \"range\": {
        \"@timestamp\": {\"gte\": \"$SINCE\"}
      }
    },
    \"size\": 5,
    \"sort\": [{\"@timestamp\": {\"order\": \"desc\"}}]
  }")

RECENT_COUNT=$(echo "$RECENT_HITS" | python3 -c "
import json,sys
data=json.load(sys.stdin)
total=data.get('hits',{}).get('total',{})
if isinstance(total, dict): print(total.get('value',0))
else: print(total)
" 2>/dev/null || echo "0")

# ── Step 5: 네임스페이스별 분포 확인 ──────────────────────
info "Step 5: 네임스페이스별 로그 분포..."
curl -s "http://localhost:${LOCAL_PORT}/logs-*/_search" \
  -H 'Content-Type: application/json' \
  -d '{"size":0,"aggs":{"namespaces":{"terms":{"field":"kubernetes.namespace_name","size":20}}}}' \
  | python3 -c "
import json,sys
data=json.load(sys.stdin)
aggs=data.get('aggregations',{}).get('namespaces',{}).get('buckets',[])
for b in aggs: print('   ', b.get('key',''), ':', b.get('doc_count',0), '개')
" 2>/dev/null || true

# ── Step 6: 최근 샘플 도큐먼트 출력 ──────────────────────
info "Step 6: 최근 수집 샘플 (3개)..."
echo "$RECENT_HITS" | python3 -c "
import json,sys
data=json.load(sys.stdin)
hits=data.get('hits',{}).get('hits',[])
for h in hits[:3]:
  src=h.get('_source',{})
  k8s=src.get('kubernetes',{})
  print('  인덱스:', h.get('_index',''))
  print('  @timestamp:', src.get('@timestamp',''))
  print('  namespace:', k8s.get('namespace_name',''))
  print('  pod:', k8s.get('pod_name',''))
  print('  log:', str(src.get('log',''))[:100])
  print()
" 2>/dev/null || true

# ── Step 7: 최종 판정 ─────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "${RECENT_COUNT:-0}" -gt 0 ]; then
  success "SMOKE TEST PASSED"
  echo "  Fluentbit DS: $READY/$DESIRED Ready"
  echo "  총 인덱싱 도큐먼트: $DOC_COUNT"
  echo "  최근 60초 내 도큐먼트: $RECENT_COUNT"
else
  fail "SMOKE TEST FAILED: 최근 60초 내 로그가 OpenSearch에서 발견되지 않음"
  echo ""
  echo "  디버그: Fluentbit 로그 마지막 20줄"
  kubectl -n "$FLUENTBIT_NS" logs ds/"$FLUENTBIT_DS" --tail=20 2>/dev/null || true
  exit 1
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
