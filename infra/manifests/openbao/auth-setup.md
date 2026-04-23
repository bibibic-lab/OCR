# OpenBao — Kubernetes Auth + KV v2 설정 Runbook

## 목적

External Secrets Operator(ESO)가 OpenBao에서 시크릿을 읽을 수 있도록:
1. KV v2 시크릿 엔진 활성화
2. Kubernetes auth method 활성화
3. ESO용 정책(Policy) 생성
4. ServiceAccount 바인딩 롤(Role) 생성
5. 테스트 시크릿 초기 적재

## 전제 조건

| 항목 | 확인 방법 |
|---|---|
| OpenBao 파드 Running | `kubectl -n security get pod openbao-0` |
| openbao-init-keys Secret 존재 | `kubectl -n security get secret openbao-init-keys` |
| ESO 설치 완료 | `kubectl -n external-secrets get pods` |

## 실행 (자동화 스크립트)

```bash
# 멱등적 실행 — 이미 활성화된 항목은 건너뜀
bash scripts/openbao-eso-bootstrap.sh
```

## 수동 단계 (참고)

### 1. root token 확인

```bash
ROOT_TOKEN=$(kubectl -n security get secret openbao-init-keys \
  -o jsonpath='{.data.init\.json}' | base64 -d | jq -r .root_token)
echo "root token length: ${#ROOT_TOKEN}"
```

### 2. KV v2 활성화

```bash
kubectl -n security exec openbao-0 -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
  bao secrets enable -path=kv -version=2 kv
```

이미 활성화된 경우: `Error enabling: Error making API request ... path is already in use` 무시.

### 3. Kubernetes auth 활성화

```bash
kubectl -n security exec openbao-0 -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
  bao auth enable kubernetes
```

### 4. Kubernetes auth 구성

OpenBao 파드 내부에서 실행 (SA 토큰·CA 자동 마운트 이용):

```bash
kubectl -n security exec openbao-0 -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
  bao write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
```

> **주의**: `issuer` 파라미터는 kind 클러스터에서는 생략해도 동작합니다.
> 프로덕션 EKS/GKE에서는 `issuer` 명시 필요.

### 5. ESO 정책 생성

```bash
kubectl -n security exec openbao-0 -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
  bao policy write eso-admin-reader - <<'EOF'
path "kv/data/admin/*" {
  capabilities = ["read"]
}
path "kv/metadata/admin/*" {
  capabilities = ["read", "list"]
}
EOF
```

### 6. Kubernetes 롤 생성

```bash
kubectl -n security exec openbao-0 -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
  bao write auth/kubernetes/role/eso-admin-reader \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="eso-admin-reader" \
    ttl="1h"
```

### 7. 테스트 시크릿 적재

```bash
AUTH_SECRET=$(openssl rand -base64 32)
# KEYCLOAK_CLIENT_SECRET 은 Keycloak admin-ui 클라이언트에서 복사
KEYCLOAK_CLIENT_SECRET="<backoffice-client-secret-here>"

kubectl -n security exec openbao-0 -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
  bao kv put kv/admin/admin-ui-env \
    AUTH_SECRET="$AUTH_SECRET" \
    KEYCLOAK_CLIENT_SECRET="$KEYCLOAK_CLIENT_SECRET"
```

## 검증

```bash
# KV 목록 확인
kubectl -n security exec openbao-0 -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
  bao kv list kv/admin

# 시크릿 값 확인
kubectl -n security exec openbao-0 -- \
  env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN="$ROOT_TOKEN" \
  bao kv get kv/admin/admin-ui-env
```

## 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| `403 permission denied` | 정책 미생성 or 롤 바인딩 불일치 | `bao policy read eso-admin-reader` 확인 |
| `connection refused` | OpenBao 미기동 or TLS 오류 | `kubectl -n security logs openbao-0` |
| ClusterSecretStore `Ready=False` | ca.crt 불일치 | `kubectl -n security get secret openbao-tls -o yaml` |
| ExternalSecret `SecretSyncError` | kv 경로 오타 | `bao kv get kv/admin/admin-ui-env` |

## 관련 파일

- `infra/manifests/external-secrets/cluster-secret-store.yaml`
- `infra/manifests/external-secrets/admin-ui-env-externalsecret.yaml`
- `scripts/openbao-eso-bootstrap.sh`
- `tests/smoke/external_secrets_smoke.sh`
