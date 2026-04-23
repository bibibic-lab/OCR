#!/usr/bin/env bash
# argocd_drift_report.sh — ArgoCD 드리프트 현황 리포트 (읽기 전용)
#
# 목적: 모든 ArgoCD Application의 sync 상태와 diff를 파일로 저장
# 주의: 어떤 sync도 수행하지 않음 — 관찰 전용
# 작성: 2026-04-22 Phase 1 Medium #2 Step 2
#
# 사용법:
#   ./tests/smoke/argocd_drift_report.sh [출력_디렉터리]
#   기본 출력: /tmp/argocd-drift-$(date +%Y%m%d-%H%M%S)/

set -euo pipefail

REPORT_DIR="${1:-/tmp/argocd-drift-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$REPORT_DIR"

echo "=== ArgoCD Drift Report ===" | tee "$REPORT_DIR/summary.txt"
echo "생성일시: $(date '+%Y-%m-%d %H:%M:%S %Z')" | tee -a "$REPORT_DIR/summary.txt"
echo "출력 디렉터리: $REPORT_DIR" | tee -a "$REPORT_DIR/summary.txt"
echo "" | tee -a "$REPORT_DIR/summary.txt"

# ArgoCD CLI 존재 여부 확인
if ! command -v argocd &>/dev/null; then
  echo "[WARNING] argocd CLI 미설치. kubectl로 대체합니다." | tee -a "$REPORT_DIR/summary.txt"
  USE_KUBECTL=true
else
  USE_KUBECTL=false
fi

# ── 1. Application 목록 ──────────────────────────────────────────────────────
echo "## 1. Application 목록" | tee -a "$REPORT_DIR/summary.txt"
kubectl -n argocd get application -o wide 2>/dev/null | tee -a "$REPORT_DIR/summary.txt" | tee "$REPORT_DIR/01-application-list.txt"
echo "" | tee -a "$REPORT_DIR/summary.txt"

# ── 2. ApplicationSet 목록 ───────────────────────────────────────────────────
echo "## 2. ApplicationSet 목록" | tee -a "$REPORT_DIR/summary.txt"
kubectl -n argocd get applicationset 2>/dev/null | tee -a "$REPORT_DIR/summary.txt" | tee "$REPORT_DIR/02-applicationset-list.txt"
echo "" | tee -a "$REPORT_DIR/summary.txt"

# ── 3. OutOfSync Application 목록 ────────────────────────────────────────────
echo "## 3. OutOfSync Applications" | tee -a "$REPORT_DIR/summary.txt"
kubectl -n argocd get application -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' 2>/dev/null \
  | sort | tee "$REPORT_DIR/03-sync-status.txt" | tee -a "$REPORT_DIR/summary.txt"
echo "" | tee -a "$REPORT_DIR/summary.txt"

OUT_OF_SYNC=$(kubectl -n argocd get application -o jsonpath='{range .items[*]}{.status.sync.status}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep "^OutOfSync" | awk '{print $2}' || true)

echo "## 4. OutOfSync 상세 (argocd app diff)" | tee -a "$REPORT_DIR/summary.txt"
if [ -z "$OUT_OF_SYNC" ]; then
  echo "  OutOfSync Application 없음" | tee -a "$REPORT_DIR/summary.txt"
else
  COUNT=0
  for APP in $OUT_OF_SYNC; do
    COUNT=$((COUNT+1))
    echo "### [$COUNT] $APP" | tee -a "$REPORT_DIR/summary.txt"
    DIFF_FILE="$REPORT_DIR/04-diff-${APP}.txt"

    if [ "$USE_KUBECTL" = "false" ]; then
      # argocd CLI 사용
      argocd app diff "$APP" --refresh 2>/dev/null > "$DIFF_FILE" || true
      head -50 "$DIFF_FILE" | tee -a "$REPORT_DIR/summary.txt"
    else
      # argocd CLI 없음 — kubectl로 status만
      kubectl -n argocd get application "$APP" -o jsonpath='{.status}' 2>/dev/null \
        | python3 -m json.tool 2>/dev/null > "$DIFF_FILE" || true
      echo "  (argocd CLI 미설치 — status JSON 저장: $DIFF_FILE)" | tee -a "$REPORT_DIR/summary.txt"
    fi
    echo "" | tee -a "$REPORT_DIR/summary.txt"
  done
fi

# ── 5. Application별 마지막 sync 이력 ─────────────────────────────────────────
echo "## 5. Application 상태 상세 (kubectl)" | tee -a "$REPORT_DIR/summary.txt"
kubectl -n argocd get application -o json 2>/dev/null \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item['metadata']['name']
    sync = item.get('status', {}).get('sync', {}).get('status', 'Unknown')
    health = item.get('status', {}).get('health', {}).get('status', 'Unknown')
    msg = item.get('status', {}).get('conditions', [{}])
    sync_rev = item.get('status', {}).get('sync', {}).get('revision', '-')[:8]
    print(f'  {name:<40} sync={sync:<12} health={health:<12} rev={sync_rev}')
" 2>/dev/null | tee "$REPORT_DIR/05-app-details.txt" | tee -a "$REPORT_DIR/summary.txt"

echo "" | tee -a "$REPORT_DIR/summary.txt"
echo "=== 리포트 완료 ===" | tee -a "$REPORT_DIR/summary.txt"
echo "파일 목록:" | tee -a "$REPORT_DIR/summary.txt"
ls -la "$REPORT_DIR/" | tee -a "$REPORT_DIR/summary.txt"

echo ""
echo "Summary 파일: $REPORT_DIR/summary.txt"
