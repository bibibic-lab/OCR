# Runbook: Log Shipper (Fluentbit → OpenSearch)

- **작성일**: 2026-04-23
- **최종 수정일**: 2026-04-23 (Phase 1 Low #2 — OpenSearch security 활성화)
- **작성자**: Claude Code
- **관련 컴포넌트**: Fluentbit DaemonSet (kube-system), OpenSearch (observability)
- **상태**: 운영 중 (security 활성화)

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
| OpenSearch 보안 | **활성화** (Phase 1 Low #2, 2026-04-23) — HTTPS + 사용자 인증 |

### 관련 파일

| 파일 | 설명 |
|---|---|
| `infra/helm/values/dev/fluentbit.yaml` | Fluentbit Helm values |
| `infra/helm/values/dev/opensearch.yaml` | OpenSearch Helm values (security 설정 포함) |
| `infra/manifests/fluentbit/index-template.yaml` | OpenSearch 인덱스 템플릿 등록 Job |
| `infra/manifests/fluentbit/fluentbit-to-opensearch-netpol.yaml` | NetworkPolicy (kube-system → observability:9200) |
| `infra/manifests/fluentbit/fluentbit-opensearch-externalsecret.yaml` | Fluentbit 인증 Secret ESO (kube-system) |
| `infra/manifests/observability/opensearch-externalsecrets.yaml` | admin/fluentbit 인증 Secret ESO (observability) |
| `infra/manifests/observability/opensearch-bootstrap-users.yaml` | security 초기화 Job (admin 해시, fluentbit 사용자, logs_writer role) |
| `tests/smoke/logs_smoke.sh` | 연결 검증 스모크 테스트 |

---

## 2. OpenSearch Security 구성 (Phase 1 Low #2, 2026-04-23)

### 활성화된 보안 기능

| 기능 | 상태 | 비고 |
|---|---|---|
| Security Plugin | 활성화 | `plugins.security.disabled: false` |
| Transport TLS | 활성화 | demo self-signed cert (dev) |
| HTTP REST TLS | 활성화 | demo self-signed cert (dev) |
| 인증 | 필수 | HTTP Basic Auth |
| admin 사용자 | ESO → OpenBao | `kv/observability/opensearch-admin` |
| fluentbit 사용자 | ESO → OpenBao | `kv/observability/opensearch-fluentbit` |
| logs_writer role | `logs-*` write 권한 | fluentbit에 할당 |

### 비밀번호 관리

비밀번호는 OpenBao KV에 저장, ESO가 Kubernetes Secret으로 동기화:
- `kv/observability/opensearch-admin` → `opensearch-admin-creds` (observability ns)
- `kv/observability/opensearch-fluentbit` → `opensearch-fluentbit-creds` (observability + kube-system ns)

### OpenBao 비밀번호 조회 (root token 필요)

```bash
VAULT_TOKEN=$(kubectl get secret -n security openbao-init-keys \
  -o jsonpath='{.data.init\.json}' | base64 -d | python3 -c "import json,sys; print(json.load(sys.stdin)['root_token'])")

kubectl exec -n security openbao-0 -- sh -c "
  BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true VAULT_TOKEN=${VAULT_TOKEN} \
  bao kv get kv/observability/opensearch-admin
"
```

### Security Bootstrap 재실행 (pod 재시작 후 사용자 분실 시)

```bash
# 기존 Job 삭제 후 재실행 (ttlSecondsAfterFinished로 자동 삭제됨)
kubectl delete job -n observability opensearch-security-bootstrap --ignore-not-found
kubectl apply -f infra/manifests/observability/opensearch-bootstrap-users.yaml
kubectl logs -n observability -l job-name=opensearch-security-bootstrap -f
```

---

## 3. 빠른 상태 확인

```bash
# DaemonSet 상태
kubectl -n kube-system get ds fluent-bit

# 파드 상태 (4노드 기준 4개 Running)
kubectl -n kube-system get pods -l app.kubernetes.io/name=fluent-bit

# OpenSearch 클러스터 헬스 (admin 인증 필요)
ADMIN_PASS=$(kubectl get secret -n observability opensearch-admin-creds -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n observability ocr-logs-master-0 -- curl -sk \
  -u "admin:${ADMIN_PASS}" 'https://localhost:9200/_cluster/health?pretty'

# OpenSearch 인덱스 목록 (HTTPS + 인증)
kubectl -n observability port-forward svc/opensearch-cluster-master 19200:9200 &
ADMIN_PASS=$(kubectl get secret -n observability opensearch-admin-creds -o jsonpath='{.data.password}' | base64 -d)
curl -sk -u "admin:${ADMIN_PASS}" 'https://localhost:19200/_cat/indices/logs-*?v'
kill %1

# 스모크 테스트 실행
bash tests/smoke/logs_smoke.sh
```

---

## 4. 재설치 / 업그레이드

### Fluentbit Helm upgrade

```bash
helm upgrade fluent-bit fluent/fluent-bit \
  --namespace kube-system \
  --version 0.48.10 \
  -f infra/helm/values/dev/fluentbit.yaml \
  --wait --timeout=120s
```

### OpenSearch Helm upgrade

```bash
helm upgrade opensearch opensearch/opensearch \
  --namespace observability \
  --version 2.21.0 \
  -f infra/helm/values/dev/opensearch.yaml \
  --wait --timeout=10m
# 업그레이드 후 security bootstrap 재실행 권장
kubectl delete job -n observability opensearch-security-bootstrap --ignore-not-found
kubectl apply -f infra/manifests/observability/opensearch-bootstrap-users.yaml
```

### OpenSearch 인덱스 템플릿 재등록

```bash
kubectl apply -f infra/manifests/fluentbit/index-template.yaml
kubectl -n observability logs job/opensearch-index-template --follow
```

---

## 5. 주요 NetworkPolicy

```
kube-system (Fluentbit) → observability (OpenSearch:9200)
파일: infra/manifests/fluentbit/fluentbit-to-opensearch-netpol.yaml
```

**참고**: `kube-system`은 PSS(PodSecurity Standards) 미적용 네임스페이스로, Fluentbit의 hostPath 볼륨(/var/log) 마운트를 허용. `observability`는 `baseline` PSS가 적용되어 있어 Fluentbit을 이 ns에 설치할 수 없음.

---

## 6. 로그 쿼리 예시

OpenSearch에 port-forward 후 (HTTPS + 인증 필요):

```bash
kubectl -n observability port-forward svc/opensearch-cluster-master 19200:9200 &
PF_PID=$!
ADMIN_PASS=$(kubectl get secret -n observability opensearch-admin-creds -o jsonpath='{.data.password}' | base64 -d)

# 특정 네임스페이스 로그 검색
curl -sk -u "admin:${ADMIN_PASS}" \
  "https://localhost:19200/logs-*/_search" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"term":{"kubernetes.namespace_name":"processing"}},"size":10,"sort":[{"@timestamp":{"order":"desc"}}]}'

# 특정 파드 로그 검색
curl -sk -u "admin:${ADMIN_PASS}" \
  "https://localhost:19200/logs-*/_search" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"term":{"kubernetes.pod_name":"upload-api-xxx"}},"size":10,"sort":[{"@timestamp":{"order":"desc"}}]}'

# 키워드 검색
curl -sk -u "admin:${ADMIN_PASS}" \
  "https://localhost:19200/logs-*/_search" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"match":{"log":"ERROR"}},"size":10,"sort":[{"@timestamp":{"order":"desc"}}]}'

kill $PF_PID
```

---

## 7. 트러블슈팅

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
# Fluentbit → OpenSearch 연결 테스트 (HTTPS + 인증)
FB_PASS=$(kubectl get secret -n kube-system opensearch-fluentbit-creds -o jsonpath='{.data.password}' | base64 -d)
kubectl run test-curl --image=curlimages/curl:8.7.1 -n kube-system --rm -it \
  --command -- curl -sk -u "fluentbit:${FB_PASS}" \
  https://opensearch-cluster-master.observability.svc.cluster.local:9200/_cluster/health
```

**주요 원인**:
- NetworkPolicy 미적용: `infra/manifests/fluentbit/fluentbit-to-opensearch-netpol.yaml` 확인
- OpenSearch pod 레이블 불일치: 현재 `app.kubernetes.io/name=opensearch`
- 인증 실패: `opensearch-fluentbit-creds` Secret 동기화 확인

```bash
# NetworkPolicy 확인
kubectl -n observability get networkpolicy allow-fluentbit-from-kube-system -o yaml

# ExternalSecret 동기화 상태
kubectl get externalsecret -n kube-system opensearch-fluentbit-creds
```

### 증상: OpenSearch 401 Unauthorized

```bash
# Security bootstrap 재실행
kubectl delete job -n observability opensearch-security-bootstrap --ignore-not-found
kubectl apply -f infra/manifests/observability/opensearch-bootstrap-users.yaml
kubectl logs -n observability -l job-name=opensearch-security-bootstrap -f
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

## 8. 알려진 제한 사항 및 이월 항목

| 항목 | 우선순위 | 담당 Phase |
|---|---|---|
| ~~OpenSearch security plugin 비활성화 상태 (인증 없음)~~ | ~~High~~ | **완료** (Phase 1 Low #2, 2026-04-23) |
| Transport/HTTP TLS — demo self-signed 인증서 사용 | Medium | Phase 2 (cert-manager Certificate로 교체) |
| 비밀번호 rotation 자동화 미적용 | Medium | Phase 2 (ESO refresh로 커버 가능) |
| security bootstrap Job 수동 재실행 필요 (ArgoCD hook으로 자동화 예정) | Medium | Phase 2 |
| Keycloak SAML SSO 연동 미적용 | Low | Phase 2 |
| 로그 보존 정책(ISM, 7일 삭제) 미적용 | Medium | Phase 1 Low #3 |
| Grafana + OpenSearch 대시보드 미구성 | Low | Phase 1 Low #3 |
| `admin`, `dmz` 네임스페이스 로그 수집 미확인 | Low | 자동 수집됨 (활동 시) |

---

## 9. 인덱스 템플릿 스펙

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
