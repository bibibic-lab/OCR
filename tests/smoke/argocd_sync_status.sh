#!/usr/bin/env bash
# argocd_sync_status.sh — ArgoCD Application 동기화 상태 읽기 전용 요약
# Phase 1 Medium #2 Step 3 산출물
# 실행: ./tests/smoke/argocd_sync_status.sh [--json]
# 의존성: kubectl

set -euo pipefail

JSON_MODE="${1:-}"

echo "==================================================="
echo "ArgoCD Application Sync Status"
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "==================================================="

python3 - "$JSON_MODE" << 'PYEOF'
import sys, json, subprocess

json_mode = '--json' in sys.argv

raw = subprocess.check_output(
    ['kubectl', '-n', 'argocd', 'get', 'applications', '-o', 'json']
).decode()
data = json.loads(raw)
apps = data.get('items', [])

if json_mode:
    result = [{'name': a['metadata']['name'],
               'sync': a['status']['sync']['status'],
               'health': a['status']['health']['status']}
              for a in apps]
    print(json.dumps(sorted(result, key=lambda x: x['name']), indent=2))
    sys.exit(0)

synced = []; outofsync = []; unknown = []; other = []
for a in apps:
    name = a['metadata']['name']
    sync = a['status']['sync']['status']
    health = a['status']['health']['status']
    phase = a.get('status',{}).get('operationState',{}).get('phase','')
    row = f"  {name:50s}  sync={sync:12s}  health={health:12s}  op={phase}"
    if sync == 'Synced' and health in ('Healthy', 'Degraded', 'Progressing'):
        synced.append(row)
    elif 'Unknown' in (sync, health):
        unknown.append(row)
    elif sync == 'OutOfSync':
        outofsync.append(row)
    else:
        other.append(row)

print(f"\n[SYNCED: {len(synced)}]")
for r in sorted(synced): print(r)
print(f"\n[OUT_OF_SYNC: {len(outofsync)}]")
for r in sorted(outofsync): print(r)
print(f"\n[UNKNOWN: {len(unknown)}]")
for r in sorted(unknown): print(r)
if other:
    print(f"\n[OTHER: {len(other)}]")
    for r in sorted(other): print(r)

total = len(apps)
sc = len(synced)
print(f"\n=== SUMMARY: Synced={sc}/{total} OutOfSync={len(outofsync)} Unknown={len(unknown)} ===")
PYEOF
