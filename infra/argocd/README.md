# ArgoCD App-of-Apps — OCR Platform GitOps

## 구조 개요

```
infra/argocd/
├── README.md                      # 이 파일
├── root-app.yaml                  # App-of-Apps 루트 Application
└── apps/
    ├── _namespaces.yaml           # Namespace 사전 생성 (sync-wave: -1)
    ├── 00-cilium.yaml             # Cilium CNI 1.19.1
    ├── 01-cert-manager.yaml       # cert-manager v1.14.5
    ├── 02-cnpg.yaml               # CloudNative-PG 0.20.2
    ├── 03-external-secrets.yaml   # External Secrets Operator 2.3.0
    ├── 04-openbao.yaml            # OpenBao 0.5.0 (Vault fork)
    ├── 05-seaweedfs.yaml          # SeaweedFS 4.0.0
    ├── 06-keycloak.yaml           # Bitnami Keycloak 25.2.0
    ├── 07-opensearch.yaml         # OpenSearch 2.21.0
    ├── 08-fluentbit.yaml          # Fluent Bit 0.48.10
    ├── 09-kps.yaml                # kube-prometheus-stack 58.4.0
    ├── 10-manifests.yaml          # ApplicationSet — infra/manifests/* 전체
    └── 99-argocd-self.yaml        # ArgoCD 자체 (마지막 sync-wave)
```

## Sync Policy (Phase 1)

**모든 Application/ApplicationSet은 `automated: null` (수동 sync)** 으로 설정됩니다.

- 이유: 최초 ArgoCD 등록 후 cluster 현재 상태와 git 간 드리프트를 관찰하고, Step 3에서 해소한 뒤 automated sync를 활성화합니다.
- auto-sync 활성화 시점: Step 3 드리프트 해소 완료 후, 각 Application별로 개별 활성화

## Sync Wave 순서

| Wave | Application | 이유 |
|------|-------------|------|
| -1   | _namespaces | 모든 ns가 먼저 존재해야 함 |
| 0    | ocr-root + cilium | CNI 최우선 |
| 1    | cert-manager | TLS 인증서 발급 선행 |
| 2    | cnpg | DB 오퍼레이터 (Postgres cluster 전제) |
| 3    | external-secrets | Secret 동기화 (DB/Keycloak 전제) |
| 4    | openbao | Secret 저장소 (external-secrets 전제) |
| 5    | seaweedfs | 스토리지 |
| 6    | keycloak | IdP (DB + TLS 전제) |
| 7    | opensearch + fluentbit | 로그 파이프라인 |
| 8    | kps | 모니터링 |
| 10   | manifests-* | 워크로드 CR/Deployment/NP |
| 99   | argocd-self | 자기 자신 마지막 |

## Multi-Source 패턴

Helm Chart Application은 모두 ArgoCD multi-source를 사용합니다:
- Source 1: 공식 Helm chart repo (chart + version)
- Source 2: OCR repo (`ref: values`) → `infra/helm/values/dev/<release>.yaml` 참조

```yaml
sources:
  - repoURL: https://helm.cilium.io
    targetRevision: 1.19.1
    chart: cilium
    helm:
      valueFiles:
        - $values/infra/helm/values/dev/cilium.yaml
  - repoURL: https://github.com/bibibic-lab/OCR
    targetRevision: main
    ref: values
```

## ignoreDifferences 주의사항

| 리소스 | 무시 필드 | 이유 |
|--------|-----------|------|
| StatefulSet | `/spec/volumeClaimTemplates` | Kubernetes immutable 필드 |
| MutatingWebhookConfiguration | `/webhooks/*/clientConfig/caBundle` | cert-manager 동적 갱신 |
| CiliumNetworkPolicy | `/status` | controller 자동 갱신 |
| Secret | `/data` | 운영 중 수동 생성 값 보호 |

## 운영 절차

### 초기 배포 (Step 2 — 이번 단계)

```bash
# 1. root-app 등록
kubectl apply -f infra/argocd/root-app.yaml

# 2. 자식 Application 생성 관찰 (자동 — root-app이 infra/argocd/apps/ 스캔)
kubectl -n argocd get application -w

# 3. 드리프트 확인 (sync 하지 않음)
./tests/smoke/argocd_drift_report.sh
```

### 드리프트 해소 (Step 3 — 다음 단계)

```bash
# 단일 Application sync (예: cert-manager)
argocd app sync ocr-cert-manager --dry-run
argocd app sync ocr-cert-manager

# manifests ApplicationSet 중 특정 컴포넌트
argocd app sync manifests-postgres --dry-run
argocd app sync manifests-postgres
```

### Auto-sync 활성화 (Step 3 이후)

```yaml
# 각 yaml 파일 수정
syncPolicy:
  automated:
    prune: false      # 초기: prune 비활성 (안전)
    selfHeal: true    # drift 자동 복구
```

## 주의사항

1. **OpenBao**: `infra/manifests/openbao/auto-unseal.yaml`은 `manifests-openbao` Application이 관리. helm chart Application(`ocr-openbao`)과 별개.
2. **Keycloak realm-ocr.json**: `infra/manifests/keycloak/realm-ocr.json`은 ArgoCD가 sync 시도하지 않도록 주의. 운영 중 realm 수동 수정이 있었을 수 있음.
3. **postgres Cluster CR**: CNPG Cluster는 `manifests-postgres` Application이 관리. 복구 시 data loss 가능성이 있으므로 sync 전 반드시 dry-run.
4. **cilium k8sServiceHost**: `infra/helm/values/dev/cilium.yaml`의 `k8sServiceHost`는 kind 클러스터 IP (`192.168.97.5`). 클러스터 재생성 시 변경 필요.
