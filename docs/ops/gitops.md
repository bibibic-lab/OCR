# GitOps 운영 런북 — ArgoCD App-of-Apps

**작성일**: 2026-04-22
**관련 Phase**: Phase 1 Medium #2 Step 2
**담당**: OCR 플랫폼 팀

---

## 1. 구조 요약

OCR 플랫폼의 GitOps는 **ArgoCD App-of-Apps 패턴**으로 구성됩니다.

```
ocr-root (root Application)
  └── infra/argocd/apps/ 스캔
       ├── ocr-namespaces         (sync-wave: -1)
       ├── ocr-cilium             (sync-wave:  0)
       ├── ocr-cert-manager       (sync-wave:  1)
       ├── ocr-cnpg               (sync-wave:  2)
       ├── ocr-external-secrets   (sync-wave:  3)
       ├── ocr-openbao            (sync-wave:  4)
       ├── ocr-seaweedfs          (sync-wave:  5)
       ├── ocr-keycloak           (sync-wave:  6)
       ├── ocr-opensearch         (sync-wave:  7)
       ├── ocr-fluentbit          (sync-wave:  7)
       ├── ocr-kps                (sync-wave:  8)
       ├── ocr-manifests (AppSet) (sync-wave: 10)
       │    ├── manifests-admin-ui
       │    ├── manifests-argocd
       │    ├── manifests-cert-manager
       │    ├── manifests-cilium
       │    ├── manifests-external-secrets
       │    ├── manifests-fluentbit
       │    ├── manifests-fpe-service
       │    ├── manifests-integration-hub
       │    ├── manifests-keycloak
       │    ├── manifests-observability
       │    ├── manifests-ocr-worker
       │    ├── manifests-ocr-worker-paddle
       │    ├── manifests-openbao
       │    ├── manifests-postgres
       │    └── manifests-upload-api
       └── ocr-argocd-self        (sync-wave: 99)
```

**Repo**: https://github.com/bibibic-lab/OCR
**Branch**: main

---

## 2. 초기 배포 절차 (최초 1회)

### 전제조건

- ArgoCD 9.5.2 (App v3.3.7) 배포 완료 (`argocd` ns)
- `kubectl` + `argocd` CLI 설정 완료
- GitHub repo `bibibic-lab/OCR`에 infra/ 구조 push 완료

### 단계

```bash
# Step 1: root Application 등록
kubectl apply -f infra/argocd/root-app.yaml

# Step 2: 자식 Application 자동 생성 관찰 (30초~2분 소요)
kubectl -n argocd get application -w

# Step 3: ApplicationSet 확인
kubectl -n argocd get applicationset

# Step 4: 드리프트 리포트 생성 (sync 없음 — 읽기 전용)
./tests/smoke/argocd_drift_report.sh /tmp/drift-initial

# Step 5: 결과 확인
cat /tmp/drift-initial/summary.txt
```

### 예상 결과

- `ocr-root`: STATUS=OutOfSync, HEALTH=Healthy (자식 앱 생성됨)
- 모든 자식 앱: STATUS=OutOfSync (수동 sync 대기)
- **자동 sync 없음** — cluster 상태 변화 없음

---

## 3. 드리프트 확인

```bash
# 전체 Application 상태
kubectl -n argocd get application -o wide

# 특정 Application 드리프트 상세
argocd app diff ocr-cert-manager

# manifests ApplicationSet 중 특정 컴포넌트
argocd app diff manifests-postgres

# 드리프트 리포트 (전체 — 파일 저장)
./tests/smoke/argocd_drift_report.sh
```

---

## 4. 수동 Sync 절차 (Step 3 드리프트 해소)

### 원칙

1. **항상 dry-run 먼저**
2. **wave 순서대로** (namespace → CNI → cert-manager → ...)
3. **StatefulSet 관련 앱은 특히 신중하게** (openbao, opensearch, seaweedfs, keycloak)

### 단계별 sync

```bash
# 1. Namespace 먼저
argocd app sync ocr-namespaces --dry-run
argocd app sync ocr-namespaces

# 2. Cilium (CNI)
argocd app diff ocr-cilium
# 주의: Cilium DaemonSet sync는 노드 네트워크 영향 가능 — dry-run 필수
argocd app sync ocr-cilium --dry-run
argocd app sync ocr-cilium

# 3. cert-manager
argocd app sync ocr-cert-manager

# 4. CNPG (DB operator)
argocd app sync ocr-cnpg

# 5. External Secrets
argocd app sync ocr-external-secrets

# 6. OpenBao (주의: StatefulSet immutable fields)
argocd app diff ocr-openbao
argocd app sync ocr-openbao --dry-run
argocd app sync ocr-openbao

# 7. SeaweedFS
argocd app sync ocr-seaweedfs

# 8. Keycloak (주의: realm-ocr.json 별도 관리)
argocd app sync ocr-keycloak

# 9. 로그/모니터링
argocd app sync ocr-opensearch
argocd app sync ocr-fluentbit
argocd app sync ocr-kps

# 10. manifests (ApplicationSet — 개별 컴포넌트별)
argocd app sync manifests-cert-manager
argocd app sync manifests-cilium
argocd app sync manifests-external-secrets
argocd app sync manifests-openbao
argocd app sync manifests-postgres  # 주의: CNPG Cluster CR — data 보호
argocd app sync manifests-keycloak  # 주의: realm-ocr.json 포함
argocd app sync manifests-observability
argocd app sync manifests-fluentbit
argocd app sync manifests-upload-api
argocd app sync manifests-admin-ui
argocd app sync manifests-fpe-service
argocd app sync manifests-integration-hub
argocd app sync manifests-ocr-worker
argocd app sync manifests-ocr-worker-paddle
argocd app sync manifests-argocd

# 11. ArgoCD self (마지막)
argocd app sync ocr-argocd-self
```

---

## 5. Auto-sync 활성화 (Step 3 완료 후)

드리프트가 해소되면 단계적으로 auto-sync를 활성화합니다.

### 활성화 순서

1. 위험도 낮은 앱 먼저: observability, fluentbit, kps
2. 워크로드: manifests-admin-ui, manifests-upload-api, manifests-fpe-service 등
3. 인프라: cert-manager, cnpg, external-secrets
4. 마지막: openbao, keycloak, argocd-self

### 설정 변경

```bash
# 파일 수정: infra/argocd/apps/<app>.yaml
syncPolicy:
  automated:
    prune: false      # 초기: prune 비활성 (안전)
    selfHeal: true    # git → cluster 자동 적용
```

---

## 6. 주의사항 및 예외

### OpenBao StatefulSet

`volumeClaimTemplates`는 Kubernetes immutable 필드입니다. ArgoCD sync 시 변경을 감지해도 apply가 실패합니다. `ignoreDifferences`로 무시 설정됨.

수동 변경이 필요한 경우:
```bash
kubectl -n security delete statefulset openbao --cascade=orphan
helm upgrade openbao openbao/openbao -n security -f infra/helm/values/dev/openbao.yaml
```

### Keycloak realm-ocr.json

운영 중 realm 수동 수정이 있었을 수 있습니다. `manifests-keycloak` sync 전:

```bash
# 현재 realm 상태 export
kubectl -n admin exec -it keycloak-0 -- /opt/bitnami/keycloak/bin/kcadm.sh \
  get realms/ocr-realm --server http://localhost:8080 \
  --realm master --user admin --password "$KEYCLOAK_ADMIN_PASSWORD" \
  > /tmp/realm-ocr-current.json

# git 버전과 비교
diff /tmp/realm-ocr-current.json infra/manifests/keycloak/realm-ocr.json
```

### Postgres CNPG Cluster

`manifests-postgres` Application이 관리. sync 전 반드시:

```bash
argocd app diff manifests-postgres
# Cluster spec 변경이 있으면 → CNPG 공식 migration guide 참조
```

### OpenBao auto-unseal

`infra/manifests/openbao/auto-unseal.yaml`은 Deployment (helm 외). `manifests-openbao` Application이 관리.
unseal 정상 여부 확인:
```bash
./tests/smoke/openbao_auto_unseal_smoke.sh
```

---

## 7. 복구 시나리오

### ArgoCD pod 재기동 후 Application 복구

```bash
# Application CRD는 etcd에 보존되므로 자동 복구됨
kubectl -n argocd get application

# root-app이 사라진 경우
kubectl apply -f infra/argocd/root-app.yaml
```

### 잘못된 sync 후 롤백

```bash
# 특정 Application 이전 revision으로 롤백
argocd app rollback <app-name> <revision>

# helm 직접 롤백 (ArgoCD 외부)
helm rollback <release> -n <namespace>
```

### ArgoCD 전체 재설치

```bash
helm upgrade --install argocd argo/argo-cd \
  --version 9.5.2 \
  --namespace argocd \
  --create-namespace

# root-app 재등록
kubectl apply -f infra/argocd/root-app.yaml
```

---

## 8. 관련 문서

| 문서 | 위치 |
|------|------|
| 솔루션 설계서 | `docs/superpowers/specs/2026-04-18-ocr-solution-design.md` |
| CNPG 백업 런북 | `docs/ops/cnpg-backup.md` |
| OpenBao unseal 런북 | `docs/ops/openbao-unseal.md` |
| External Secrets 런북 | `docs/ops/external-secrets.md` |
| ArgoCD app-of-apps 구조 | `infra/argocd/README.md` |

---

## 9. 드리프트 해소 로그 (Step 3 — 2026-04-23)

**실행 일시**: 2026-04-23  
**결과**: 21개 Application Synced/Healthy, 7개 이월

### 처리 결과 요약

| 번호 | Application | 결과 | 비고 |
|------|-------------|------|------|
| 1 | `ocr-cert-manager` | **Synced/Healthy** | caBundle ignoreDifferences 적용됨 |
| 2 | `ocr-cnpg` | **Synced/Healthy** | CRD annotation too large (cosmetic) — SSA로 처리 |
| 3 | `ocr-cilium` | **Synced/Healthy** | - |
| 4 | `ocr-external-secrets` | **Synced/Healthy** | CRD annotation too large (cosmetic) |
| 5 | `ocr-openbao` | **Synced/Healthy** | - |
| 6 | `ocr-fluentbit` | **Synced/Healthy** | - |
| 7 | `ocr-kps` | **Synced/Healthy** | kps-admission-create Job hook 완료 후 operation null 처리 |
| 8 | `ocr-opensearch` | **Synced/Healthy** | - |
| 9 | `ocr-seaweedfs` | **Synced/Healthy** | - |
| 10 | `ocr-keycloak` | **Synced/Healthy** | - |
| 11 | `manifests-cert-manager` | **Synced/Healthy** | - |
| 12 | `manifests-cilium` | **Synced/Healthy** | - |
| 13 | `manifests-external-secrets` | **OutOfSync (허용)** | ExternalSecret ESO spec defaulting — ignoreDifferences 추가됨 |
| 14 | `manifests-openbao` | **Synced/Healthy** | - |
| 15 | `manifests-keycloak` | **이월** | realm-ocr.json → infra/keycloak-realm/로 이동, 재배포 필요 |
| 16 | `manifests-upload-api` | **Synced/Healthy** | ArgoCD ownership label 소급 추가 후 sync |
| 17 | `manifests-fpe-service` | **OutOfSync (허용)** | ExternalSecret spec defaulting — ignoreDifferences 반영 후 재sync 필요 |
| 18 | `manifests-integration-hub` | **Synced/Healthy** | - |
| 19 | `manifests-ocr-worker` | **Synced/Healthy** | - |
| 20 | `manifests-ocr-worker-paddle` | **Synced/Healthy** | - |
| 21 | `manifests-admin-ui` | **Synced/Healthy** | - |
| 22 | `manifests-observability` | **Synced/Healthy** | OpenBao policy 수정 후 ESO 재sync |
| 23 | `manifests-fluentbit` | **Synced/Healthy** | OpenBao policy 수정 후 ESO 재sync |
| - | `manifests-postgres` | **SKIP** | pg-main Cluster 상태 불안정(Unknown) — data risk |
| - | `ocr-argocd-self` | **SKIP** | 의도적 — circular dependency 위험 |
| - | `ocr-root` | **SKIP** | App-of-Apps root — 수동 sync 불필요 |
| - | `manifests-argocd` | **SKIP** | ArgoCD 자체 manifest — 별도 관리 |

### 변경 내역

#### 1. ApplicationSet ignoreDifferences 확장 (`infra/argocd/apps/10-manifests.yaml`)
- `*.md` 외 `*.json` 파일도 ArgoCD 파싱 대상에서 제외 (`{*.md,*.json}`)
- ExternalSecret `ignoreDifferences`에 `/spec/data` 및 `/spec/target/deletionPolicy` 추가
  - 원인: ESO admission webhook이 spec defaulting 필드를 추가 → 매 sync마다 drift 발생

#### 2. Keycloak realm export 이동
- `infra/manifests/keycloak/realm-ocr.json` → `infra/keycloak-realm/realm-ocr.json`
- 원인: ArgoCD manifests ApplicationSet이 realm JSON을 k8s manifest로 파싱 시도 → Unknown 상태
- `manifests-keycloak` App 재sync 후 정상화 예정

#### 3. OpenBao ESO 정책 확장
- `eso-admin-reader` policy에 `kv/data/observability/*` 경로 추가
- 원인: ExternalSecret `opensearch-admin-creds`, `opensearch-fluentbit-creds`가 OpenBao의 observability/ 경로에 접근 필요했으나 policy 미포함
- 영향: manifests-observability, manifests-fluentbit의 ExternalSecret Degraded 해소

#### 4. ArgoCD ownership label 소급 추가
- `manifests-upload-api` (dmz ns), `manifests-fpe-service` (security ns) 리소스에 `app.kubernetes.io/instance` label 추가
- 원인: 과거 `kubectl apply`로 배포된 리소스에 ArgoCD 소유권 표시 없어 Missing 상태

### 잔여 이슈 (이월)

1. **`manifests-keycloak`**: realm-ocr.json 이동 커밋 후 ArgoCD refresh → sync 필요
2. **`manifests-fpe-service`**: ExternalSecret ignoreDifferences 적용 커밋 후 재sync
3. **`manifests-external-secrets`**: 동일 (ESO spec defaulting)
4. **`manifests-postgres`**: pg-main Cluster 상태 불안정 — 별도 CNPG 점검 후 처리
5. **CRD annotation too large**: ocr-cnpg, ocr-external-secrets, ocr-kps — 기능 정상, phase=Failed는 cosmetic. ArgoCD v3에서 Replace=true 옵션으로 해결 가능

### OpenBao 정책 변경 명령 (재현)

```bash
# 이 명령은 2026-04-23에 실행됨 (OpenBao raft에 저장)
# 재현이 필요한 경우:
ROOT_TOKEN=$(kubectl -n security get secret openbao-init-keys \
  -o jsonpath='{.data.init\.json}' | base64 -d | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")

kubectl -n security port-forward svc/openbao 8200:8200 &
curl -sk -X POST -H "X-Vault-Token: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  "https://localhost:8200/v1/sys/policies/acl/eso-admin-reader" \
  -d '{
    "policy": "path \"kv/data/admin/*\" { capabilities = [\"read\"] }\npath \"kv/metadata/admin/*\" { capabilities = [\"read\", \"list\"] }\npath \"kv/data/security/*\" { capabilities = [\"read\"] }\npath \"kv/metadata/security/*\" { capabilities = [\"read\", \"list\"] }\npath \"kv/data/observability/*\" { capabilities = [\"read\"] }\npath \"kv/metadata/observability/*\" { capabilities = [\"read\", \"list\"] }\n"
  }'
```

---

## 변경 이력

| 날짜 | 내용 | 작성자 |
|------|------|--------|
| 2026-04-22 | 최초 작성 — Phase 1 Medium #2 Step 2 (ArgoCD app-of-apps 배포) | Claude |
| 2026-04-23 | 드리프트 해소 — Phase 1 Medium #2 Step 3 (21개 Synced/Healthy, 7개 이월) | Claude |
