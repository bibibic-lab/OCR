# 네트워크 정책 운영 가이드 (NetworkPolicy / CNP / CCNP)

> 최초 작성: 2026-04-22  
> 적용 클러스터: `kind-ocr-dev` (Cilium 1.19.1, k8s 1.35.0)

---

## 1. 클러스터 네트워크 정책 구조

이 클러스터는 **Cilium 1.19.1 CNI** 를 사용하며, 세 가지 정책 리소스를 혼용한다.

| 리소스 | API | 범위 | 주요 용도 |
|--------|-----|------|-----------|
| `NetworkPolicy` | `networking.k8s.io/v1` | 네임스페이스 | 일반 L3/L4 허용 규칙 |
| `CiliumNetworkPolicy` (CNP) | `cilium.io/v2` | 네임스페이스 | Cilium-native L3~L7 (FQDN, HTTP method, Kafka 등) |
| `CiliumClusterwideNetworkPolicy` (CCNP) | `cilium.io/v2` | 클러스터 전체 | 전 ns 공통 베이스라인 정책 |

### 1.1 네임스페이스 기본 정책

모든 네임스페이스는 `default-deny` NP 를 가진다 (ingress + egress 모두 차단 후 명시 허용).  
공통 허용 규칙은 각 ns 의 NP 파일에 포함:

- `allow-dns` — CoreDNS(53/udp, 53/tcp) egress
- `allow-apiserver-egress` — kube-apiserver egress (→ CCNP 로 클러스터 전역 적용)
- `allow-intra-namespace` — 동일 ns 내부 통신
- `allow-metrics-scrape` — observability ns → 8080/tcp Prometheus 스크래핑

### 1.2 현재 적용된 CCNP 목록

| 이름 | 설명 |
|------|------|
| `allow-all-to-apiserver` | 전 pod → kube-apiserver egress 허용 (additive, enableDefaultDeny.egress=false) |
| `allow-cnpg-operator-to-instances` | CNPG operator → pg instance pods ingress 허용 |

### 1.3 현재 적용된 CNP 목록

| 네임스페이스 | 이름 | 설명 |
|--------------|------|------|
| `kube-system` | `hubble-relay-allow-egress` | hubble-relay → CoreDNS + hubble-peer(4244) |
| `security` | `allow-cnpg-webhook-from-apiserver` | CNPG webhook ← apiserver |
| `security` | `allow-webhook-from-apiserver` | cert-manager webhook ← apiserver |
| `dmz` | `upload-api-egress-cnp` | upload-api egress CNP 마이그레이션 데모 |

---

## 2. k8s NP vs CNP vs CCNP — 선택 기준

### k8s NetworkPolicy 를 사용하는 경우

- **단순 L3/L4 허용** 이 목적이며 FQDN/HTTP method 필터가 불필요할 때
- **이식성** 이 중요한 경우 (CNI 교체 가능성이 있을 때)
- 팀이 Cilium에 익숙하지 않을 때

**제한사항**: `kube-apiserver`, `host`, `remote-node` 같은 Cilium entity를  
`ipBlock` 으로 매칭할 수 없음 → 이 경우 반드시 CNP 사용.

### CiliumNetworkPolicy (CNP) 를 사용하는 경우

- **FQDN-based egress** 가 필요할 때 (`toFQDNs`)
- **HTTP method/path** 또는 Kafka topic 수준 L7 필터가 필요할 때
- `kube-apiserver`, `kube-dns`, `host` 같은 Cilium **entity** 를 명시해야 할 때
- Hubble 에서 **도메인명으로** 트래픽을 관측하고 싶을 때
- pod identity 기반 (`toEndpoints`) 매칭이 더 정확한 경우

### CiliumClusterwideNetworkPolicy (CCNP) 를 사용하는 경우

- **전 네임스페이스에 적용되는 베이스라인 규칙** (예: 전 pod → apiserver)
- `endpointSelector: {}` 처럼 클러스터 전역 매칭이 필요할 때
- 특정 ns 에 종속되지 않는 cross-namespace egress 패턴

---

## 3. `allow-all-to-apiserver` CCNP 수정 이력

### 3.1 문제 발견 (2026-04-22)

`allow-all-to-apiserver` CCNP 의 원래 명세:

```yaml
spec:
  endpointSelector: {}          # 모든 pod 매칭
  egress:
    - toEntities:
        - kube-apiserver
```

**의도**: "모든 pod 에서 kube-apiserver 로의 egress 를 허용한다 (additive)."

**실제 동작**: Cilium 은 egress 규칙이 있는 policy 가 endpoint 에 적용될 때  
해당 방향(egress)의 default-deny 를 **자동 활성화**한다.  
→ `endpointSelector: {}` 가 전 pod 를 매칭하므로, **모든 pod의 egress 가**  
`kube-apiserver` 방향을 제외한 모든 곳으로 **차단**된다.

**증상**: Hubble Relay 가 CoreDNS(53/udp), hubble-peer(4244/tcp) 로 연결 불가  
→ `CrashLoopBackOff` 지속.  
(임시 우회: `hubble-relay-allow-egress` CNP 추가)

### 3.2 수정 방법 (Approach A — enableDefaultDeny)

Cilium 1.14+ 에서 지원되는 `enableDefaultDeny` 필드를 사용:

```yaml
spec:
  endpointSelector: {}
  enableDefaultDeny:
    egress: false             # ← 추가: 이 정책이 egress default-deny 를 트리거하지 않음
  egress:
    - toEntities:
        - kube-apiserver
```

`enableDefaultDeny.egress: false` 는 이 정책을 **additive allow** 로 전환한다.  
매칭된 pod 에 default-deny egress 를 부과하지 않아, 다른 egress 트래픽에 영향 없음.

**검토한 대안들:**

| 방법 | 설명 | 채택 여부 |
|------|------|-----------|
| **A: enableDefaultDeny** | egress default-deny 비활성화 | ✅ 채택 (간단, Cilium 1.14+) |
| B: endpointSelector 좁히기 | cnpg/cert-manager/argocd/cilium-operator 만 매칭 | 보류 (관리 복잡도↑) |
| C: CCNP 분리 | 컨트롤러별 별도 CCNP | 불필요 중복 |

### 3.3 사후 처리

수정 적용 후 `hubble-relay-allow-egress` CNP 는 중복이 되었지만 **의도적으로 유지**.  
이유: 향후 CCNP 가 다시 좁혀질 경우 hubble-relay 의 safety net 역할.  
제거 시 확인 사항: `kubectl -n kube-system get pod -l k8s-app=hubble-relay` Running 유지 확인 후 삭제.

---

## 4. upload-api egress 마이그레이션 (NP → CNP)

### 4.1 마이그레이션 배경

기존 `NetworkPolicy/upload-api-egress` 는 `namespaceSelector` 로 processing/admin ns 를 허용.  
Cilium KubeProxyReplacement 환경에서 ClusterIP DNAT 이후 pod label 매칭이 불안정할 수 있어  
`CiliumNetworkPolicy/upload-api-egress-cnp` 를 추가로 생성함.

### 4.2 CNP 가 NP 대비 추가 제공하는 것

| 항목 | 기존 NP | 신규 CNP |
|------|---------|---------|
| 목적지 매칭 | namespaceSelector | toEndpoints (Cilium identity) |
| Keycloak 허용 | ns+port | FQDN (`keycloak.admin.svc.cluster.local`) |
| DNS | port-only | toEndpoints(kube-dns) |
| Hubble 가시성 | IP 레벨 | identity/도메인 레벨 |

### 4.3 공존 규칙

`upload-api-egress` (NP) 와 `upload-api-egress-cnp` (CNP) 는 **병렬로 적용**.  
Cilium 은 NP·CNP 를 OR semantics 로 평가 → 어느 쪽이라도 허용이면 통과.  
기존 NP 를 제거할 준비가 되면 CNP 단독으로 충분한지 smoke test 후 삭제.

---

## 5. 디버깅 가이드

### 5.1 정책 드롭 확인

```bash
# 특정 ns 의 최근 드롭 이벤트 (Hubble)
kubectl -n kube-system exec deploy/hubble-relay -- \
  hubble observe --namespace dmz --type drop --last 50

# 전체 드롭 (Cilium metrics)
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg metrics list | grep cilium_drop_count_total
```

### 5.2 정책 셀렉터 확인

```bash
# 어떤 policy 가 어떤 identity 를 매칭하는지
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg policy selectors

# 특정 pod 의 적용 정책 (pod IP 사용)
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg endpoint list
```

### 5.3 Hubble observe 예시

```bash
# upload-api egress 트래픽 관찰 (policy 적용 포함)
hubble observe --namespace dmz \
  --from-pod dmz/upload-api \
  --verdict FORWARDED,DROPPED \
  --last 100

# FQDN 해석 확인
hubble observe --namespace dmz \
  --from-pod dmz/upload-api \
  --to-fqdn keycloak.admin.svc.cluster.local
```

### 5.4 CNP 상태 확인

```bash
# 모든 CNP/CCNP 유효성 확인
kubectl get cnp -A
kubectl get ccnp

# 특정 CNP 상세 (status.conditions 포함)
kubectl -n dmz get cnp upload-api-egress-cnp -o yaml
```

---

## 6. 향후 마이그레이션 후보

| 우선순위 | 대상 | 방향 | 이점 |
|----------|------|------|------|
| Medium | `ocr-worker-paddle` ingress NP | → CNP | HTTP POST /ocr method 필터 |
| Low | `pg-main` ingress NP | → CNP | PostgreSQL L7 가시성 (Cilium proxy, 부하 주의) |
| Low | argocd egress NP | → CNP | argocd → GitHub FQDN egress |

> **주의**: PostgreSQL L7 proxy 는 Cilium envoy sidecar 를 요구하며 지연 증가 가능.  
> 운영 환경 적용 전 반드시 성능 테스트 수행.
