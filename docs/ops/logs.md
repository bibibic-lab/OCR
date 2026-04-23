# Runbook: Log Shipper (Fluentbit → OpenSearch)

- **작성일**: 2026-04-23
- **작성자**: Claude Code (Phase 1 Low #1 구현)
- **관련 컴포넌트**: Fluentbit DaemonSet (kube-system), OpenSearch (observability)
- **상태**: 운영 중

---

## 1. 개요

### 아키텍처

```
각 노드의 kubelet → /var/log/containers/*.log (containerd CRI 포맷)
                                    ↓
Fluentbit DaemonSet (kube-system, 각 노드 1개)
  - tail input: /var/log/containers/*.log
  - Kubernetes metadata filter (pod/ns/container 메타데이터 추가)
                                    ↓
OpenSearch (observability ns, ocr-logs-master-{0,1,2})
  인덱스: logs-YYYY.MM.DD (일별 rotation)
```

### 설치 정보

| 항목 | 값 |
|---|---|
| Helm chart | fluent/fluent-bit 0.48.10 (app 3.2.10) |
| Helm release | fluent-bit (kube-system) |
| values 파일 | `infra/helm/values/dev/fluentbit.yaml` |
| OpenSearch | observability/ocr-logs-master-{0,1,2} |
| OpenSearch 인덱스 | logs-YYYY.MM.DD |
| OpenSearch 보안 | disabled (Phase 0 dev) — Phase 1+ 복구 예정 |

### 관련 파일

| 파일 | 설명 |
|---|---|
| `infra/helm/values/dev/fluentbit.yaml` | Fluentbit Helm values |
| `infra/manifests/fluentbit/index-template.yaml` | OpenSearch 인덱스 템플릿 등록 Job |
| `infra/manifests/fluentbit/fluentbit-to-opensearch-netpol.yaml` | NetworkPolicy (kube-system → observability:9200) |
| `tests/smoke/logs_smoke.sh` | 연결 검증 스모크 테스트 |

---

## 2. 빠른 상태 확인

```bash
# DaemonSet 상태
kubectl -n kube-system get ds fluent-bit

# 파드 상태 (4노드 기준 4개 Running)
kubectl -n kube-system get pods -l app.kubernetes.io/name=fluent-bit

# OpenSearch 인덱스 목록
kubectl -n observability port-forward svc/opensearch-cluster-master 19200:9200 &
curl -s http://localhost:19200/_cat/indices/logs-*?v
kill %1

# 스모크 테스트 실행
bash tests/smoke/logs_smoke.sh
```

---

## 3. 재설치 / 업그레이드

### Helm upgrade

```bash
helm upgrade fluent-bit fluent/fluent-bit \
  --namespace kube-system \
  --version 0.48.10 \
  -f infra/helm/values/dev/fluentbit.yaml \
  --wait --timeout=120s
```

### OpenSearch 인덱스 템플릿 재등록

```bash
kubectl apply -f infra/manifests/fluentbit/index-template.yaml
kubectl -n observability logs job/opensearch-index-template --follow
```

---

## 4. 주요 NetworkPolicy

```
kube-system (Fluentbit) → observability (OpenSearch:9200)
파일: infra/manifests/fluentbit/fluentbit-to-opensearch-netpol.yaml
```

**참고**: `kube-system`은 PSS(PodSecurity Standards) 미적용 네임스페이스로, Fluentbit의 hostPath 볼륨(/var/log) 마운트를 허용. `observability`는 `baseline` PSS가 적용되어 있어 Fluentbit을 이 ns에 설치할 수 없음.

---

## 5. 로그 쿼리 예시

OpenSearch에 port-forward 후:

```bash
kubectl -n observability port-forward svc/opensearch-cluster-master 19200:9200 &
PF_PID=$!

# 특정 네임스페이스 로그 검색
curl -s http://localhost:19200/logs-*/_search \
  -H 'Content-Type: application/json' \
  -d '{"query":{"term":{"kubernetes.namespace_name":"processing"}},"size":10,"sort":[{"@timestamp":{"order":"desc"}}]}'

# 특정 파드 로그 검색
curl -s http://localhost:19200/logs-*/_search \
  -H 'Content-Type: application/json' \
  -d '{"query":{"term":{"kubernetes.pod_name":"upload-api-xxx"}},"size":10,"sort":[{"@timestamp":{"order":"desc"}}]}'

# 키워드 검색
curl -s http://localhost:19200/logs-*/_search \
  -H 'Content-Type: application/json' \
  -d '{"query":{"match":{"log":"ERROR"}},"size":10,"sort":[{"@timestamp":{"order":"desc"}}]}'

kill $PF_PID
```

---

## 6. 트러블슈팅

### 증상: Fluentbit 파드 CrashLoopBackOff

```bash
kubectl -n kube-system logs ds/fluent-bit --tail=50
kubectl -n kube-system describe pod <fluent-bit-pod>
```

**주요 원인**:
- ConfigMap 파싱 오류: `undefined value` → `infra/helm/values/dev/fluentbit.yaml` config 섹션 확인
- 빈 값 key (예: `HTTP_User` 뒤에 값 없이 단독 줄) → 삭제 또는 값 지정

### 증상: OpenSearch 연결 타임아웃

```bash
# Fluentbit → OpenSearch 연결 테스트 (debug pod 활용)
kubectl run test-curl --image=curlimages/curl:8.7.1 -n kube-system --rm -it \
  --command -- curl -s http://opensearch-cluster-master.observability.svc.cluster.local:9200/_cluster/health
```

**주요 원인**:
- NetworkPolicy 미적용: `infra/manifests/fluentbit/fluentbit-to-opensearch-netpol.yaml` 확인
- OpenSearch pod 레이블 불일치: 현재 `app.kubernetes.io/name=opensearch`

```bash
# NetworkPolicy 확인
kubectl -n observability get networkpolicy allow-fluentbit-from-kube-system -o yaml
```

### 증상: 특정 네임스페이스 로그 미수집

- 해당 ns 파드에 `fluentbit.io/exclude: "true"` 애노테이션 없는지 확인
- Fluentbit tail이 해당 노드에서 로그 파일을 찾지 못하는 경우: `kubectl logs` 로 파드가 stdout/stderr에 출력하는지 확인
- `K8S-Logging.Exclude On` 설정으로 파드 애노테이션 기반 제외 활성화 상태임

### 증상: OpenSearch 디스크 공간 부족

- 현재 retention 정책 없음 (Phase 1+ ISM Policy 예정)
- 임시 조치: 오래된 인덱스 수동 삭제

```bash
# 7일 이전 인덱스 목록
curl -s http://localhost:19200/_cat/indices/logs-*?v

# 특정 인덱스 삭제
curl -X DELETE http://localhost:19200/logs-2026.04.01
```

---

## 7. 알려진 제한 사항 및 이월 항목

| 항목 | 우선순위 | 담당 Phase |
|---|---|---|
| OpenSearch security plugin 비활성화 상태 (인증 없음) | High | Phase 1 Low #2 |
| 로그 보존 정책(ISM, 7일 삭제) 미적용 | Medium | Phase 1 Low #3 |
| Grafana + OpenSearch 대시보드 미구성 | Low | Phase 1 Low #3 |
| `admin`, `dmz` 네임스페이스 로그 수집 미확인 | Low | 자동 수집됨 (활동 시) |

---

## 8. 인덱스 템플릿 스펙

인덱스 패턴: `logs-*`

| 필드 | 타입 | 설명 |
|---|---|---|
| `@timestamp` | date | 로그 발생 시각 |
| `log` | text | 원본 로그 메시지 |
| `stream` | keyword | stdout/stderr |
| `kubernetes.namespace_name` | keyword | 네임스페이스 |
| `kubernetes.pod_name` | keyword | 파드명 |
| `kubernetes.container_name` | keyword | 컨테이너명 |
| `kubernetes.host` | keyword | 노드명 |
| `kubernetes.labels` | object (disabled) | 파드 레이블 (인덱싱 제외) |

설정: shards=1, replicas=0 (dev), refresh_interval=10s
