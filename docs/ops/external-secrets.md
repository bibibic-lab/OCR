# External Secrets Operator + OpenBao KV v2 — 운영 Runbook

## 개요

| 항목 | 값 |
|---|---|
| 작성일 | 2026-04-23 |
| 상태 | 운영 중 |
| ESO 버전 | v2.3.0 (chart 2.3.0) |
| ESO namespace | `external-secrets` |
| OpenBao namespace | `security` |
| KV 경로 | `kv/` (v2) |
| ClusterSecretStore | `openbao-kv` |

## 아키텍처

```
[ESO Controller]                    [OpenBao]
external-secrets ns                 security ns
  external-secrets SA  --k8s auth→  kv/admin/admin-ui-env
  (eso-admin-reader role)              ↓
        ↓                         ExternalSecret reconcile
  [admin-ui-env ExternalSecret]   (refreshInterval: 1m)
        ↓
  [admin-ui-env Secret] ← k8s Secret in admin ns
        ↓
  [admin-ui Deployment]
```

## 현재 관리 대상 시크릿

| OpenBao KV 경로 | 생성되는 k8s Secret | 네임스페이스 | 키 |
|---|---|---|---|
| `kv/admin/admin-ui-env` | `admin-ui-env` | `admin` | `AUTH_SECRET`, `KEYCLOAK_CLIENT_SECRET` |

## 설치 정보

### ESO Helm 설치

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --version 2.3.0 \
  --set installCRDs=true \
  --wait --timeout 5m
```

### OpenBao 초기 설정

```bash
# KV v2 + Kubernetes auth + 정책·롤 일괄 설정 (멱등)
bash scripts/openbao-eso-bootstrap.sh
```

자세한 수동 단계: `infra/manifests/openbao/auth-setup.md`

### 매니페스트 적용

```bash
# NetworkPolicy (ESO → OpenBao 8200/TCP)
kubectl apply -f infra/manifests/external-secrets/netpol-eso-to-openbao.yaml

# ClusterSecretStore
kubectl apply -f infra/manifests/external-secrets/cluster-secret-store.yaml

# ExternalSecret
kubectl apply -f infra/manifests/external-secrets/admin-ui-env-externalsecret.yaml
```

## 일상 운영

### 시크릿 rotation

```bash
# OpenBao에서 값 갱신 → ESO가 최대 1분 내 자동 동기화
ROOT_TOKEN=$(kubectl -n security get secret openbao-init-keys \
  -o jsonpath='{.data.init\.json}' | base64 -d | jq -r .root_token)

kubectl -n security exec openbao-0 -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
  bao kv put kv/admin/admin-ui-env \
    AUTH_SECRET="$(openssl rand -base64 32)" \
    KEYCLOAK_CLIENT_SECRET="<실제값>"

# 동기화 확인
kubectl -n admin get secret admin-ui-env -o jsonpath='{.data.AUTH_SECRET}' | base64 -d
```

> **참고**: Secret이 갱신되어도 admin-ui 파드는 자동 재시작하지 않습니다.
> 환경변수가 Secret volume으로 마운트된 경우 파일은 kubelet TTL(기본 60s)마다 갱신됩니다.
> 즉시 반영이 필요하면 파드를 수동 재시작하세요: `kubectl -n admin rollout restart deployment/admin-ui`

### 상태 확인

```bash
# ESO 파드
kubectl -n external-secrets get pods

# ClusterSecretStore 상태
kubectl get clustersecretstore openbao-kv

# ExternalSecret 상태
kubectl -n admin get externalsecret admin-ui-env

# 동기화된 Secret 키 확인
kubectl -n admin get secret admin-ui-env -o jsonpath='{.data}' | jq 'keys'
```

### 새 시크릿 추가 방법

1. OpenBao에 데이터 적재:
   ```bash
   bao kv put kv/<namespace>/<secret-name> KEY1=val1 KEY2=val2
   ```
2. OpenBao 정책 확인 (경로가 `kv/data/<namespace>/*` 패턴이면 기존 정책 적용됨)
3. ExternalSecret 매니페스트 작성 (`infra/manifests/external-secrets/`)
4. `kubectl apply`

## 스모크 테스트

```bash
bash tests/smoke/external_secrets_smoke.sh
```

검증 항목:
1. ESO 파드 Ready
2. ClusterSecretStore Ready=True
3. ExternalSecret 적용 후 Secret 생성 (<30s)
4. OpenBao rotate 후 Secret 자동 업데이트 (<90s)

## NetworkPolicy

### security ns — OpenBao ingress 허용 (ESO 전용)

파일: `infra/manifests/external-secrets/netpol-eso-to-openbao.yaml`

- `allow-eso-ingress` (security ns): external-secrets ns → openbao 8200/TCP
- `allow-eso-to-openbao-egress` (external-secrets ns): ESO → security ns 8200/TCP + DNS + apiserver

### 추가 네임스페이스에서 OpenBao 접근이 필요한 경우

1. `allow-eso-ingress`에 해당 ns namespaceSelector 추가
2. 해당 ns에 OpenBao용 egress NetworkPolicy 추가

## 트러블슈팅

### ClusterSecretStore Ready=False

```bash
kubectl describe clustersecretstore openbao-kv
kubectl -n external-secrets logs deployment/external-secrets | grep -i vault
```

| 원인 | 확인 | 조치 |
|---|---|---|
| TLS CA 불일치 | `kubectl -n security get secret openbao-tls -o jsonpath='{.data.ca\.crt}'` | ca.crt 재확인 |
| NetworkPolicy 차단 | ESO 파드에서 `curl -k https://openbao.security.svc.cluster.local:8200` | netpol 재적용 |
| OpenBao 미기동 | `kubectl -n security get pod openbao-0` | 파드 상태 확인 |

### ExternalSecret SecretSyncError

```bash
kubectl -n admin describe externalsecret admin-ui-env
```

| 원인 | 조치 |
|---|---|
| KV 경로 없음 | `bao kv get kv/admin/admin-ui-env` |
| 정책 권한 부족 | `bao policy read eso-admin-reader` |
| 롤 바인딩 오류 | `bao read auth/kubernetes/role/eso-admin-reader` |

### OpenBao kubernetes auth 토큰 만료

롤의 `ttl=1h` 설정으로 ESO가 자동 갱신합니다.
로그에 `401 Unauthorized` 연속 발생 시: `kubectl -n external-secrets rollout restart deployment/external-secrets`

## 이월 항목 (Phase 1 carry-over)

| 항목 | 우선순위 | 설명 |
|---|---|---|
| `upload-api-db-creds` 마이그레이션 | Phase 2 | 현재 Bootstrap Job 경로 유지. CNPG DB 비밀번호 rotation 시 필요 |
| `keycloak-dev-creds` 마이그레이션 | Phase 2 | admin ns Keycloak SA 비밀번호 |
| `ocr-internal-ca` ESO 관리 | Phase 2 | 현재 manually copied. cert-manager ClusterIssuer 연계 고려 |
| KEYCLOAK_CLIENT_SECRET 실제값 적재 | 즉시 | 현재 PLACEHOLDER. Keycloak admin-ui 클라이언트 시크릿으로 교체 필요 |
| ESO 정책 HCL 단일 라인 이슈 | 기술부채 | bootstrap script의 `bao policy write` heredoc이 exec에서 동작하지 않아 `bao write sys/policies/acl/` API로 우회. 실제 멀티라인 HCL 작성 방법 개선 필요 |

## 관련 파일

- `infra/manifests/external-secrets/install-note.md` — ESO 설치 가이드
- `infra/manifests/external-secrets/cluster-secret-store.yaml` — ClusterSecretStore
- `infra/manifests/external-secrets/admin-ui-env-externalsecret.yaml` — ExternalSecret
- `infra/manifests/external-secrets/netpol-eso-to-openbao.yaml` — NetworkPolicy
- `infra/manifests/openbao/auth-setup.md` — OpenBao 설정 Runbook
- `scripts/openbao-eso-bootstrap.sh` — 멱등 부트스트랩 스크립트
- `tests/smoke/external_secrets_smoke.sh` — 스모크 테스트
