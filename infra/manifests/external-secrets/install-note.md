# External Secrets Operator (ESO) — 설치 노트

## 전제 조건

- Helm 3.x 설치됨
- `external-secrets` namespace 없으면 자동 생성 (`--create-namespace`)
- OpenBao 가동 중 (security ns) + Kubernetes auth + KV v2 활성화 완료

## 설치 명령

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --version "0.10.x" \
  --set installCRDs=true \
  --wait --timeout 5m
```

## 버전 고정 (재현성)

프로덕션 배포 시 `0.10.x` 를 실제 pinned 버전으로 교체:

```bash
helm search repo external-secrets/external-secrets --versions | head -5
```

예: `--version 0.10.5`

## 설치 확인

```bash
kubectl -n external-secrets get pods
kubectl -n external-secrets get crds | grep external-secrets
```

기대 CRD:
- `clustersecretstores.external-secrets.io`
- `externalsecrets.external-secrets.io`
- `secretstores.external-secrets.io`

## 다음 단계

1. ClusterSecretStore 적용: `kubectl apply -f infra/manifests/external-secrets/cluster-secret-store.yaml`
2. ExternalSecret 적용: `kubectl apply -f infra/manifests/external-secrets/admin-ui-env-externalsecret.yaml`
3. 스모크 테스트: `bash tests/smoke/external_secrets_smoke.sh`

## 참고

- ESO 공식 문서: <https://external-secrets.io/latest/>
- OpenBao Vault provider: <https://external-secrets.io/latest/provider/hashicorp-vault/>
- Chart 소스: <https://github.com/external-secrets/external-secrets>
