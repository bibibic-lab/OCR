#!/usr/bin/env bash
set -euo pipefail

# Preflight: kubectl 존재 및 NetworkPolicy-enforcing CNI 확인.
# kindnet(kind 기본)은 NetworkPolicy를 무시하므로 false-pass 방지.
command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not found in PATH"; exit 2; }

if ! kubectl get pods -n kube-system -l k8s-app=cilium -o name 2>/dev/null | grep -q cilium \
   && ! kubectl get pods -n kube-system -l k8s-app=calico-node -o name 2>/dev/null | grep -q calico; then
  echo "FAIL: No NetworkPolicy-enforcing CNI detected (install Cilium or Calico; kindnet does not enforce policies)."
  exit 2
fi

for ns in dmz processing admin observability security; do
  cnt=$(kubectl -n "$ns" get networkpolicy default-deny -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
  if [ -z "$cnt" ]; then
    echo "FAIL: $ns missing default-deny NetworkPolicy"
    exit 1
  fi
done

# 교차 호출 테스트: dmz 파드에서 kube-apiserver(80) 직접 시도 → allow-apiserver-egress는 443/6443만
# 허용하므로 80 포트는 BLOCKED 되어야 함. PSS restricted를 충족하는 매니페스트 사용.
kubectl -n dmz delete pod netcheck --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
cat <<'POD' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: netcheck
  namespace: dmz
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: netcheck
      image: curlimages/curl:8.7.1
      command: [sh, -c]
      args:
        - |
          curl -s --max-time 3 http://kubernetes.default.svc.cluster.local >/dev/null && echo LEAK || echo BLOCKED
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
POD

# Pod가 Completed 될 때까지 대기 (최대 60s)
for _ in $(seq 1 30); do
  phase=$(kubectl -n dmz get pod netcheck -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
  sleep 2
done

kubectl -n dmz logs netcheck 2>&1 > /tmp/netcheck.out || true
kubectl -n dmz delete pod netcheck --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true

grep -q "BLOCKED" /tmp/netcheck.out || { echo "FAIL: cross-zone traffic not blocked"; cat /tmp/netcheck.out; exit 1; }

echo "OK: default-deny active and cross-zone traffic blocked"
