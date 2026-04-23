# Hubble Relay CoreDNS Recovery Runbook

- **작성일**: 2026-04-23
- **심각도**: Medium (Hubble observability 불능, 운영 트래픽 영향 없음)
- **소요 시간**: 약 40분 (조사 20분, 수정 20분)

---

## 증상

```
NAME                           READY   STATUS             RESTARTS   AGE
hubble-relay-999c5cd6f-8mntw   0/1     CrashLoopBackOff   432        4d
```

**로그**:
```
Failed to create peer notify client for peers change notification; will try again after the timeout has expired
error: rpc error: code = Unavailable desc = dns: A record lookup error:
lookup hubble-peer.kube-system.svc.cluster.local. on 10.96.0.10:53: read udp 10.244.1.128:44207->10.96.0.10:53: i/o timeout
```

- CoreDNS 2개 pod 모두 `1/1 Running` 상태이므로 CoreDNS 자체 문제 아님
- hubble-relay → 10.96.0.10:53 UDP DNS 조회가 타임아웃

---

## 근본 원인

### 원인: Cilium egress 정책 차단

`allow-all-to-apiserver` **CiliumClusterwideNetworkPolicy** (CCNP) 가 범인.

```yaml
spec:
  endpointSelector: {}          # 클러스터 전체 모든 pod 선택
  egress:
    - toEntities:
        - kube-apiserver        # kube-apiserver 로만 egress 허용
```

`endpointSelector: {}` 는 hubble-relay를 포함한 **모든 pod**에 매칭된다.
Cilium은 해당 CCNP가 pod를 선택하면 **egress enforcement 활성화**하고,
명시적으로 허용되지 않은 egress를 차단(default deny)한다.

결과:
| 대상 | 포트 | 허용 여부 |
|------|------|-----------|
| kube-apiserver | any | ✅ (CCNP) |
| CoreDNS (kube-dns) | 53/UDP | ❌ 차단 |
| hubble-peer svc | 443/TCP | ❌ 차단 |
| cilium DaemonSet | 4244/TCP | ❌ 차단 |

**왜 4일 동안 발견 안 됐나?**
- 다른 pod들도 동일 제약을 받지만, 대부분은 자체 NetworkPolicy/CNP가 있어 추가 egress가 열려 있음
- hubble-relay는 별도 CNP가 없었음 → kube-apiserver egress 외 전부 차단

### 확인 명령

```bash
# Cilium endpoint list - hubble-relay 확인
kubectl -n kube-system exec cilium-v9lwb -c cilium-agent -- \
  cilium-dbg endpoint list | grep -A8 "hubble-relay"
# → POLICY (ingress): Disabled, POLICY (egress): Enabled  ← egress enforcement 활성
```

```bash
# Policy drop 메트릭 (대량 drop 확인)
kubectl -n kube-system exec cilium-v9lwb -c cilium-agent -- \
  cilium-dbg metrics list | grep "drop_count"
# → cilium_drop_count_total direction=EGRESS reason=Policy denied  167432
```

---

## 조사 과정

### Fix A: CoreDNS + hubble-relay 재시작 → 실패

```bash
kubectl -n kube-system delete pod -l k8s-app=kube-dns
kubectl -n kube-system delete pod -l k8s-app=hubble-relay
```

→ 재시작 후에도 동일 DNS timeout. 일시적 문제 아님.

### Fix B: hubble-peer 엔드포인트 확인 → 정상

```bash
kubectl -n kube-system get endpoints hubble-peer
# ENDPOINTS: 192.168.97.2:4244,192.168.97.3:4244,192.168.97.4:4244 + 1 more
```

서비스 엔드포인트 정상. selector 문제 아님.

### Fix E: CiliumNetworkPolicy 추가 → 성공 ✅

```bash
kubectl apply -f infra/manifests/cilium/hubble-relay-allow-egress-cnp.yaml
kubectl -n kube-system delete pod -l k8s-app=hubble-relay
```

---

## 적용된 수정

**파일**: `infra/manifests/cilium/hubble-relay-allow-egress-cnp.yaml`

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: hubble-relay-allow-egress
  namespace: kube-system
spec:
  endpointSelector:
    matchLabels:
      k8s-app: hubble-relay
  egress:
    # CoreDNS DNS 조회
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
    # hubble-peer gRPC (cilium DaemonSet)
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: cilium
      toPorts:
        - ports:
            - port: "4244"
              protocol: TCP
            - port: "443"
              protocol: TCP
    # hubble-peer ClusterIP 경유 접근
    - toEntities:
        - cluster
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
            - port: "4244"
              protocol: TCP
```

---

## 성공 확인

### 즉시 확인

```bash
kubectl -n kube-system get pod -l k8s-app=hubble-relay
# NAME                           READY   STATUS    RESTARTS   AGE
# hubble-relay-999c5cd6f-j7p66   1/1     Running   0          24s
```

### 로그 확인 (4개 노드 모두 Connected)

```
Received peer change notification: name="kind-ocr-dev/ocr-dev-control-plane" type=PEER_ADDED
Received peer change notification: name="kind-ocr-dev/ocr-dev-worker3" type=PEER_ADDED
Received peer change notification: name="kind-ocr-dev/ocr-dev-worker2" type=PEER_ADDED
Received peer change notification: name="kind-ocr-dev/ocr-dev-worker" type=PEER_ADDED
Connected: address=192.168.97.2:4244 peer=kind-ocr-dev/ocr-dev-worker3
Connected: address=192.168.97.4:4244 peer=kind-ocr-dev/ocr-dev-worker
Connected: address=192.168.97.5:4244 peer=kind-ocr-dev/ocr-dev-control-plane
Connected: address=192.168.97.3:4244 peer=kind-ocr-dev/ocr-dev-worker2
```

---

## 예방 조치 권장 사항

1. **kube-system 네임스페이스용 기본 DNS egress CCNP 추가 고려**
   - `allow-all-to-apiserver` CCNP에 DNS egress 규칙 추가하거나
   - 별도 `allow-kube-system-dns-egress` CCNP로 분리

2. **Hubble 설치 시 CNP 자동 포함**
   - `cilium` Helm chart values에 hubble-relay CNP를 extraResources로 추가

3. **모니터링**: `cilium_drop_count_total{reason="Policy denied"}` 알람 설정
   - 기준: 1분 내 1000회 이상 → PagerDuty alert

---

## 참조

- Cilium 문서: [CiliumNetworkPolicy](https://docs.cilium.io/en/stable/network/kubernetes/policy/)
- 관련 CCNP: `allow-all-to-apiserver` (클러스터 전체 egress 제한)
- hubble-peer 서비스: `kube-system/hubble-peer` ClusterIP `10.110.114.252:443`
- Cilium 버전: `1.19.1` (helm ls -A 기준)
