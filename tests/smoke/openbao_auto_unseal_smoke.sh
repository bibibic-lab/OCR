#!/usr/bin/env bash
# tests/smoke/openbao_auto_unseal_smoke.sh
# Phase 1 smoke test: openbao-unsealer watcher Deployment이 openbao-0 재기동 후
# 자동으로 unseal 하는지 검증한다.
#
# 전제조건:
#   - openbao-unsealer Deployment가 security ns에 Ready 상태
#   - openbao-0 StatefulSet이 Running 상태
#
# 실행: bash tests/smoke/openbao_auto_unseal_smoke.sh
set -euo pipefail

NS="security"
TIMEOUT_UNSEALER=60
TIMEOUT_READY=120
POLL_INTERVAL=3

pass() { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;34mINFO\033[0m %s\n' "$*"; }

# 1) unsealer Deployment가 Available 인지 확인
info "Step 1: openbao-unsealer Deployment 준비 확인 (timeout=${TIMEOUT_UNSEALER}s)"
kubectl -n "$NS" wait --for=condition=Available deploy/openbao-unsealer \
  --timeout="${TIMEOUT_UNSEALER}s" \
  && pass "openbao-unsealer Deployment Available" \
  || fail "openbao-unsealer Deployment 준비 실패"

# 2) 현재 openbao-0 Ready 확인
info "Step 2: openbao-0 현재 상태 확인"
CURRENT_READY=$(kubectl -n "$NS" get pod openbao-0 \
  -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
if [ "$CURRENT_READY" != "true" ]; then
  info "WARN: openbao-0 이 아직 Ready 아님 (ready=$CURRENT_READY) — 먼저 unsealer가 처리하는지 확인"
  info "  (이미 sealed 상태라면 unsealer 동작만 지켜봐도 됨)"
fi

# 3) openbao-0 삭제 → StatefulSet이 자동 재생성
info "Step 3: openbao-0 pod 삭제 (grace-period=10s)"
kubectl -n "$NS" delete pod openbao-0 --grace-period=10
info "openbao-0 삭제 완료. unsealer 자동 unseal 대기 (최대 ${TIMEOUT_READY}s)..."

# 4) 최대 TIMEOUT_READY 초 동안 openbao-0 Ready 대기
MAX_ITER=$(( TIMEOUT_READY / POLL_INTERVAL ))
for i in $(seq 1 "$MAX_ITER"); do
  READY=$(kubectl -n "$NS" get pod openbao-0 \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  if [ "$READY" = "true" ]; then
    ELAPSED=$(( i * POLL_INTERVAL ))
    pass "openbao-0 auto-unseal 성공: Ready until ~${ELAPSED}s after pod deletion"
    break
  fi
  if [ "$i" -eq "$MAX_ITER" ]; then
    # 최종 상태 출력
    kubectl -n "$NS" get pod openbao-0 || true
    kubectl -n "$NS" logs deploy/openbao-unsealer --tail=30 || true
    fail "openbao-0 이 ${TIMEOUT_READY}s 내에 Ready 상태가 되지 않음 (auto-unseal 실패)"
  fi
  sleep "$POLL_INTERVAL"
done

# 5) unsealer 로그에서 unseal 성공 로그 확인
info "Step 5: unsealer 로그에서 'unseal SUCCESS' 확인"
LOGS=$(kubectl -n "$NS" logs deploy/openbao-unsealer --tail=50 2>/dev/null || echo "")
if echo "$LOGS" | grep -q "unseal SUCCESS"; then
  pass "unsealer 로그에 'unseal SUCCESS' 확인"
else
  info "WARN: 로그에서 'unseal SUCCESS' 미확인 (이미 이전 루프에서 unsealed 되었을 가능성 있음)"
  echo "--- 최근 로그 ---"
  echo "$LOGS"
fi

pass "=== openbao auto-unseal smoke test PASSED ==="
