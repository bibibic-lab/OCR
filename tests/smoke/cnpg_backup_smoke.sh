#!/usr/bin/env bash
# cnpg_backup_smoke.sh — CNPG barmanObjectStore → SeaweedFS S3 백업 검증
# Usage: bash tests/smoke/cnpg_backup_smoke.sh
# Prerequisites: kubectl context pointing at dev cluster
# 검증 항목:
#   1. pg-backups 버킷 존재 확인
#   2. pg-main Cluster ContinuousArchiving 조건 True 확인
#   3. 수동 Backup CR 트리거 및 completed 대기
#   4. S3에 backup.info 객체 존재 확인
#   5. WAL archived_count > 0 확인
set -euo pipefail

NS=processing
S3_ENDPOINT="http://seaweedfs-s3.processing.svc.cluster.local:8333"
BACKUP_AWS_KEY="dev-backup-access-key"
BACKUP_AWS_SECRET="dev-backup-secret-key"
BACKUP_NAME="pg-main-smoke-$(date +%s)"

PASS=0
FAIL=0

ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "[INFO] $*"; }

# ──────────────────────────────────────────────────────────────────────────────
# Step 1: pg-backups 버킷 존재 확인
# ──────────────────────────────────────────────────────────────────────────────
info "Step 1: pg-backups 버킷 존재 확인"
BUCKET_RESULT=$(kubectl -n "$NS" run s3-smoke-ls-"$(date +%s)" --rm -i \
  --restart=Never --image=amazon/aws-cli:2.15.30 \
  --env="AWS_ACCESS_KEY_ID=$BACKUP_AWS_KEY" \
  --env="AWS_SECRET_ACCESS_KEY=$BACKUP_AWS_SECRET" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  --command -- aws \
    --endpoint-url "$S3_ENDPOINT" \
    s3 ls 2>/dev/null || echo "ERROR")

if echo "$BUCKET_RESULT" | grep -q "pg-backups"; then
  ok "pg-backups 버킷 존재"
else
  fail "pg-backups 버킷 없음 (결과: $BUCKET_RESULT)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 2: ContinuousArchiving 조건 확인
# ──────────────────────────────────────────────────────────────────────────────
info "Step 2: pg-main ContinuousArchiving 상태 확인"
ARCH_STATUS=$(kubectl -n "$NS" get cluster pg-main \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}' 2>/dev/null || echo "Unknown")

if [ "$ARCH_STATUS" = "True" ]; then
  ok "ContinuousArchiving = True"
else
  fail "ContinuousArchiving = $ARCH_STATUS (예상: True)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 3: 수동 Backup CR 트리거
# ──────────────────────────────────────────────────────────────────────────────
info "Step 3: 수동 Backup CR 생성 — $BACKUP_NAME"
kubectl -n "$NS" apply -f - <<EOF >/dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $BACKUP_NAME
  namespace: $NS
spec:
  cluster:
    name: pg-main
  method: barmanObjectStore
EOF

# 최대 3분 대기
TIMEOUT=180
ELAPSED=0
PHASE=""
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  PHASE=$(kubectl -n "$NS" get backup "$BACKUP_NAME" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "pending")
  if [ "$PHASE" = "completed" ] || [ "$PHASE" = "failed" ]; then
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED+5))
done

BACKUP_ID=$(kubectl -n "$NS" get backup "$BACKUP_NAME" \
  -o jsonpath='{.status.backupId}' 2>/dev/null || echo "")
STARTED=$(kubectl -n "$NS" get backup "$BACKUP_NAME" \
  -o jsonpath='{.status.startedAt}' 2>/dev/null || echo "")
STOPPED=$(kubectl -n "$NS" get backup "$BACKUP_NAME" \
  -o jsonpath='{.status.stoppedAt}' 2>/dev/null || echo "")

if [ "$PHASE" = "completed" ]; then
  ok "수동 백업 completed (ID=$BACKUP_ID, start=$STARTED, stop=$STOPPED)"
else
  fail "수동 백업 phase=$PHASE (ID=$BACKUP_ID)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 4: S3 백업 객체 확인
# ──────────────────────────────────────────────────────────────────────────────
info "Step 4: S3 백업 객체 확인 (prefix=pg-main/pg-main/base/$BACKUP_ID)"
if [ -n "$BACKUP_ID" ]; then
  S3_LIST=$(kubectl -n "$NS" run s3-smoke-verify-"$(date +%s)" --rm -i \
    --restart=Never --image=amazon/aws-cli:2.15.30 \
    --env="AWS_ACCESS_KEY_ID=$BACKUP_AWS_KEY" \
    --env="AWS_SECRET_ACCESS_KEY=$BACKUP_AWS_SECRET" \
    --env="AWS_DEFAULT_REGION=us-east-1" \
    --command -- aws \
      --endpoint-url "$S3_ENDPOINT" \
      s3 ls --recursive "s3://pg-backups/pg-main/pg-main/base/$BACKUP_ID/" 2>/dev/null || echo "ERROR")

  if echo "$S3_LIST" | grep -q "backup.info"; then
    DATA_SIZE=$(echo "$S3_LIST" | awk '/data\.tar\.gz/{print $3}')
    ok "S3 백업 객체 존재 (data.tar.gz size=${DATA_SIZE:-unknown})"
  else
    fail "S3에서 backup.info 미발견 (결과: $S3_LIST)"
  fi
else
  fail "BACKUP_ID 없음 — S3 확인 불가"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 5: WAL archived_count 확인
# ──────────────────────────────────────────────────────────────────────────────
info "Step 5: WAL archived_count 확인"
WAL_STATS=$(kubectl -n "$NS" exec pg-main-1 -c postgres -- \
  psql -U postgres -d postgres -t -c \
  "SELECT archived_count, failed_count FROM pg_stat_archiver;" 2>/dev/null || echo "ERROR")

ARCHIVED=$(echo "$WAL_STATS" | awk -F'|' '{gsub(/ /,"",$1); print $1}' | head -1)
FAILED=$(echo "$WAL_STATS" | awk -F'|' '{gsub(/ /,"",$2); print $2}' | head -1)

if [ -n "$ARCHIVED" ] && [ "$ARCHIVED" -gt 0 ] 2>/dev/null; then
  ok "WAL archived_count=$ARCHIVED, failed_count=$FAILED"
else
  fail "WAL archived_count=$ARCHIVED (예상: >0), failed_count=$FAILED"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 결과 요약
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  CNPG Backup Smoke Test 결과"
echo "  PASS: $PASS / $((PASS+FAIL)) | FAIL: $FAIL"
echo "════════════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
