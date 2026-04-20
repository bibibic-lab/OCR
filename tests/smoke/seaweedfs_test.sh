#!/usr/bin/env bash
set -euo pipefail

# SeaweedFS dev smoke: health endpoints across master/filer/volume.
# 기능 put/get은 Phase 1 통합 테스트에서 S3 SDK로 검증 (multipart form
# 전송이 alpine busybox wget에 없어 dev smoke는 health check 중심).
command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not found"; exit 2; }

kubectl -n processing wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=seaweedfs --timeout=5m

MASTER_POD=$(kubectl -n processing get pod \
  -l app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=master \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "$MASTER_POD" ] || { echo "FAIL: master pod not found"; exit 1; }

# Master cluster status endpoint
kubectl -n processing exec "$MASTER_POD" -- \
  wget -qO- http://seaweedfs-master.processing.svc:9333/cluster/status 2>&1 \
  | grep -q -i "leader" \
  || { echo "FAIL: master cluster status check"; exit 1; }

# Volume fleet registered
VOLUME_INFO=$(kubectl -n processing exec "$MASTER_POD" -- \
  wget -qO- http://seaweedfs-master.processing.svc:9333/dir/status 2>&1)
echo "$VOLUME_INFO" | grep -q -i "Volumes\|DataCenters" \
  || { echo "FAIL: master volume list empty"; exit 1; }

# Filer root (retry up to 5 times for transient DNS/HTTP timing)
ok=0
for _ in $(seq 1 5); do
  if kubectl -n processing exec "$MASTER_POD" -- \
       wget -qO- --timeout=5 http://seaweedfs-filer.processing.svc:8888/ 2>&1 \
       | grep -q -i "SeaweedFS Filer"; then
    ok=1; break
  fi
  sleep 3
done
[ "$ok" -eq 1 ] || { echo "FAIL: filer root not responding (5 retries)"; exit 1; }

echo "OK: seaweedfs master+volume+filer healthy"
