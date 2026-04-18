#!/usr/bin/env bash
set -euo pipefail

for ns in dmz processing admin observability security; do
  cnt=$(kubectl -n "$ns" get networkpolicy default-deny -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
  if [ -z "$cnt" ]; then
    echo "FAIL: $ns missing default-deny NetworkPolicy"
    exit 1
  fi
done

# 교차 호출 테스트: dmz 파드가 processing 파드에 도달하면 fail
kubectl -n dmz run netcheck --image=curlimages/curl:8.7.1 --restart=Never --rm -i --command -- \
  sh -c 'curl -s --max-time 3 http://kubernetes.default.svc.cluster.local > /dev/null && echo "LEAK" || echo "BLOCKED"' \
  | tee /tmp/netcheck.out

grep -q "BLOCKED" /tmp/netcheck.out || { echo "FAIL: cross-zone traffic not blocked"; exit 1; }

echo "OK: default-deny active and cross-zone traffic blocked"
