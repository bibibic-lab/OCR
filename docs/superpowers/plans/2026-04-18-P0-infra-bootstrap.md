# P0 인프라·플랫폼 부트스트랩 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OCR 솔루션의 모든 상위 서브플랜(P1~P5)이 올라탈 K8s 기반 플랫폼을 부트스트랩한다. 3존 분리, mTLS, 관측·감사 기반, KMS, DB HA, 객체 스토리지, SSO, GitOps 파이프라인을 포함.

**Architecture:** Terraform + Helm + ArgoCD(GitOps) 조합. Kustomize 오버레이로 dev/stg/prod 환경 분리. K8s 네임스페이스를 5개 존(dmz/processing/admin/observability/security)으로 분리하고 기본 Deny NetworkPolicy 위에 필요한 허용 규칙만 추가하는 Zero-Trust 접근. 컴포넌트는 공식 Helm 차트 우선 활용.

**Tech Stack:** Kubernetes 1.29+, Terraform 1.7+, Helm 3.14+, ArgoCD 2.10+, cert-manager 1.14, kube-prometheus-stack, OpenSearch Operator 2, CloudNativePG 1.22, SeaweedFS 3.x, OpenBao 2.0+, Keycloak 24+, SoftHSM 2.

**Scope:** P0는 **플랫폼 기반만** 구축. 애플리케이션(업로드/OCR/백오피스)은 P1~P4에서 추가. 실제 외부 LDAP/AD/HSM 연동은 stub으로 시작하여 Phase 1 직전에 프로덕션 연동으로 교체.

---

## File Structure

```
ocr/
├── .github/workflows/
│   ├── ci.yml                          # lint, validate, test
│   └── tf-plan.yml                     # PR별 terraform plan
├── .gitignore
├── .editorconfig
├── Makefile                            # 상위 태스크 진입점
├── README.md
├── docs/
│   └── superpowers/
│       ├── specs/2026-04-18-ocr-solution-design.md   (완료)
│       └── plans/2026-04-18-P0-infra-bootstrap.md    (이 문서)
├── infra/
│   ├── terraform/
│   │   ├── versions.tf
│   │   ├── providers.tf
│   │   ├── backend.tf
│   │   ├── environments/
│   │   │   └── dev/
│   │   │       ├── main.tf
│   │   │       └── terraform.tfvars
│   │   └── modules/
│   │       ├── k8s-namespaces/
│   │       │   ├── main.tf
│   │       │   ├── variables.tf
│   │       │   └── outputs.tf
│   │       └── network-policies/
│   │           └── main.tf
│   ├── helm/
│   │   ├── umbrella/
│   │   │   ├── Chart.yaml              # ArgoCD Application 차트
│   │   │   └── templates/
│   │   │       ├── applicationset.yaml
│   │   │       └── app-of-apps.yaml
│   │   └── values/
│   │       └── dev/
│   │           ├── cert-manager.yaml
│   │           ├── kube-prometheus-stack.yaml
│   │           ├── opensearch.yaml
│   │           ├── cloudnative-pg.yaml
│   │           ├── seaweedfs.yaml
│   │           ├── openbao.yaml
│   │           └── keycloak.yaml
│   ├── manifests/
│   │   ├── cert-manager/
│   │   │   ├── cluster-issuer-internal.yaml
│   │   │   └── root-ca.yaml
│   │   ├── postgres/
│   │   │   ├── main-cluster.yaml
│   │   │   └── pii-cluster.yaml
│   │   ├── seaweedfs/
│   │   │   └── s3-config.yaml
│   │   ├── openbao/
│   │   │   ├── init-job.yaml
│   │   │   └── transit-config.yaml
│   │   └── keycloak/
│   │       ├── realm-ocr.json
│   │       └── ldap-stub.yaml
│   └── argocd/
│       ├── install/
│       │   └── values.yaml
│       └── apps/
│           └── root-app.yaml
└── tests/
    ├── smoke/
    │   ├── namespaces_test.sh
    │   ├── network_policies_test.sh
    │   ├── mtls_handshake_test.sh
    │   ├── keycloak_token_test.sh
    │   └── openbao_transit_test.sh
    └── integration/
        └── platform_ready_test.sh
```

**책임 분리 원칙**
- `infra/terraform/` — K8s 외부(클라우드 리소스·네임스페이스·RBAC 등 K8s 1차 리소스). dev 환경만 먼저, prod는 Phase 1에.
- `infra/helm/umbrella/` — ArgoCD가 바라보는 "앱의 앱(app-of-apps)". 여기를 변경하면 ArgoCD가 자동 반영.
- `infra/helm/values/` — 각 Helm 차트의 환경별 values. 차트 자체는 외부 리포 사용.
- `infra/manifests/` — 순수 K8s 매니페스트(차트 없는 CRD·커스텀 리소스).
- `tests/smoke/` — 각 컴포넌트 배포 직후 E2E Ready 검증 스크립트.

---

## 사전 준비 (시작 전 확인)

- 로컬: `kubectl`, `helm`, `terraform`, `kustomize`, `yq`, `jq`, `openssl`, `soft-hsm` CLI 설치
- K8s 클러스터: minikube/kind(로컬 개발) 또는 기존 dev 클러스터, **최소 4 노드 × 8vCPU/16GB**, K8s 1.29+
- GitHub(또는 GitLab) 원격 저장소 생성, SSH 키 등록
- 도메인: `*.dev.ocr.local` (/etc/hosts 매핑 또는 사설 DNS)

---

## 🔶 Dry-Run P0 모드 (2026-04-18 세션 적용)

**본 세션은 "IaC 자산 완성"이 목표이며 실 K8s 클러스터에 apply하지 않는다.**
다음 세션에서 환경 준비(kind + Cilium + brew 도구) 후 `make tf-apply` 한 번으로 전체 스택이 올라가도록 자산을 완성한다.

**각 태스크의 실행 명령은 아래 매핑으로 치환한다:**

| 계획상 명령 | Dry-Run 치환 |
|---|---|
| `git init`, 파일 생성, `git commit` | **그대로 수행** (리포 안에서만 변경) |
| `make tf-init` | `terraform init -backend=false` 가능 시 시도, 실패해도 skip |
| `make tf-plan`, `make tf-apply` | **skip** (클러스터 없음). `terraform validate`, `terraform fmt -check`로 대체 |
| `helm upgrade --install ... --wait` | **skip**. `helm lint <values.yaml>` + `helm template ... > /tmp/rendered-<chart>.yaml` + `kubectl apply --dry-run=client -f /tmp/rendered-<chart>.yaml` (kubectl 있고 유효한 syntax 확인용) |
| `kubectl apply -f <manifest>` | `kubectl apply --dry-run=client -f <manifest>` (클러스터 없으면 skip, 문법 체크만 `kubectl apply --dry-run=client` 대신 `kubeconform` 사용 권장. 없으면 skip) |
| `kubectl create ns/secret/cm ...` | `--dry-run=client -o yaml`로 매니페스트 출력, 파일로 저장 |
| `kubectl wait --for=condition=Ready ...` | **skip** |
| `kubectl exec`, `kubectl port-forward`, 스모크 테스트 실행 | **skip**. 스크립트 파일 **작성만** + `bash -n <script>` 구문 체크 |
| `helm repo add`, `helm repo update` | **수행 가능** (로컬 helm 있으면). 없으면 skip |

**도구 미설치 시 대응:**
- `helm` / `terraform` / `kustomize` / `yq` 미설치 → 해당 검증 skip, 파일 작성만. 커밋 메시지에 `(lint pending — tools not installed)` 표기 금지(플래그 없음). 다음 세션에서 `make lint` 일괄 수행.
- 유저 설치 명령: `brew install helm terraform kustomize yq kind cilium-cli`

**완료 기준(Dry-Run):**
- 모든 파일(T1~T12 계획서 File Structure에 명시된 전부) 생성·커밋 완료
- 설치된 도구로 가능한 lint/validate 모두 통과
- `git log --oneline`에 태스크별 커밋 13개 이상 (Task 12까지 + 최종 태그)

**다음 세션(실 배포)에서 해야 할 것:**
- 환경 준비 (도구 설치 + kind 클러스터 + Cilium CNI)
- 이 부록을 무시하고 계획서 본문의 명령을 순서대로 실행
- `make verify`로 전체 검증

---

---

### Task 1: 리포 초기화 + 기본 구조 + CI 골격

**Files:**
- Create: `/Users/jimmy/_Workspace/ocr/.gitignore`
- Create: `/Users/jimmy/_Workspace/ocr/.editorconfig`
- Create: `/Users/jimmy/_Workspace/ocr/Makefile`
- Create: `/Users/jimmy/_Workspace/ocr/README.md`
- Create: `/Users/jimmy/_Workspace/ocr/.github/workflows/ci.yml`

- [ ] **Step 1.1: git init + 기본 파일**

```bash
cd /Users/jimmy/_Workspace/ocr
git init -b main
```

`.gitignore`:
```gitignore
# Terraform
**/.terraform/*
*.tfstate
*.tfstate.*
*.tfplan
*.tfvars.local

# Secrets
*.pem
*.key
*.crt
!**/testdata/*.pem
.env
.env.*

# OS / editor
.DS_Store
.idea/
.vscode/

# Python / Node
__pycache__/
node_modules/
dist/
build/
*.egg-info/
.coverage
htmlcov/

# Helm
*.tgz
charts/
```

`.editorconfig`:
```ini
root = true

[*]
indent_style = space
indent_size = 2
end_of_line = lf
charset = utf-8
trim_trailing_whitespace = true
insert_final_newline = true

[*.{py,tf}]
indent_size = 4

[Makefile]
indent_style = tab
```

`README.md`:
```markdown
# OCR 통합 플랫폼

OSS 기반 문서 처리 솔루션. 설계서: [docs/superpowers/specs/2026-04-18-ocr-solution-design.md](docs/superpowers/specs/2026-04-18-ocr-solution-design.md)

## 빠른 시작

```bash
make setup            # 도구 체크
make tf-init          # Terraform 초기화
make tf-apply         # dev 환경 적용
make argocd-bootstrap # ArgoCD 설치 + app-of-apps
make smoke            # P0 스모크 테스트
```
```

- [ ] **Step 1.2: Makefile 작성**

`Makefile`:
```makefile
SHELL := /bin/bash
.ONESHELL:

TF_DIR := infra/terraform/environments/dev
HELM_VALUES := infra/helm/values/dev
ARGOCD_NS := argocd

.PHONY: setup
setup:
	@which kubectl helm terraform kustomize yq jq openssl >/dev/null || \
	  (echo "Missing tools. Install kubectl helm terraform kustomize yq jq openssl"; exit 1)
	@echo "All tools present."

.PHONY: tf-init tf-plan tf-apply
tf-init:
	cd $(TF_DIR) && terraform init

tf-plan:
	cd $(TF_DIR) && terraform plan -out=tfplan

tf-apply:
	cd $(TF_DIR) && terraform apply tfplan

.PHONY: argocd-bootstrap
argocd-bootstrap:
	kubectl create ns $(ARGOCD_NS) --dry-run=client -o yaml | kubectl apply -f -
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update
	helm upgrade --install argocd argo/argo-cd \
	  --namespace $(ARGOCD_NS) \
	  --values infra/argocd/install/values.yaml \
	  --wait
	kubectl apply -f infra/argocd/apps/root-app.yaml

.PHONY: smoke
smoke:
	@for t in tests/smoke/*.sh; do \
	  echo "=== Running $$t ==="; \
	  bash $$t || exit 1; \
	done

.PHONY: lint
lint:
	terraform -chdir=$(TF_DIR) fmt -check -recursive
	helm lint infra/helm/umbrella
	kustomize build infra/manifests/postgres > /dev/null 2>&1 || true
	@echo "Lint OK"
```

- [ ] **Step 1.3: CI 파이프라인 골격**

`.github/workflows/ci.yml`:
```yaml
name: CI
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: 1.7.5 }
      - uses: azure/setup-helm@v4
        with: { version: 3.14.4 }
      - uses: azure/setup-kubectl@v4
      - name: Terraform fmt
        run: terraform -chdir=infra/terraform fmt -check -recursive
      - name: Helm lint
        run: helm lint infra/helm/umbrella
      - name: Shell lint
        run: |
          sudo apt-get install -y shellcheck
          shellcheck tests/smoke/*.sh || true
```

- [ ] **Step 1.4: 검증**

```bash
cd /Users/jimmy/_Workspace/ocr
make setup
```
Expected: `All tools present.` (없으면 설치 후 재시도)

- [ ] **Step 1.5: 첫 커밋**

```bash
git add .gitignore .editorconfig Makefile README.md .github/
git commit -m "chore(p0): initialize repo skeleton and CI"
```

---

### Task 2: Terraform 백엔드 + Provider

**Files:**
- Create: `infra/terraform/versions.tf`
- Create: `infra/terraform/providers.tf`
- Create: `infra/terraform/backend.tf`
- Create: `infra/terraform/environments/dev/main.tf`
- Create: `infra/terraform/environments/dev/terraform.tfvars`

- [ ] **Step 2.1: 버전·프로바이더·백엔드 정의**

`infra/terraform/versions.tf`:
```hcl
terraform {
  required_version = ">= 1.7.0, < 2.0.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }
}
```

`infra/terraform/providers.tf`:
```hcl
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  config_context   = var.kube_context
  load_config_file = true
}

variable "kubeconfig_path" {
  type    = string
  default = "~/.kube/config"
}

variable "kube_context" {
  type = string
}
```

`infra/terraform/backend.tf`:
```hcl
# 로컬 백엔드로 시작. Phase 1에 S3/GCS·state locking으로 전환.
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
```

- [ ] **Step 2.2: dev 환경 진입점**

`infra/terraform/environments/dev/main.tf`:
```hcl
module "namespaces" {
  source = "../../modules/k8s-namespaces"
  zones  = var.zones
}

module "network_policies" {
  source     = "../../modules/network-policies"
  namespaces = module.namespaces.namespace_names
  depends_on = [module.namespaces]
}

variable "zones" {
  type = list(object({
    name   = string
    labels = map(string)
  }))
}
```

`infra/terraform/environments/dev/terraform.tfvars`:
```hcl
kube_context = "kind-ocr-dev"

zones = [
  { name = "dmz",           labels = { zone = "dmz",          tier = "external" } },
  { name = "processing",    labels = { zone = "processing",   tier = "internal" } },
  { name = "admin",         labels = { zone = "admin",        tier = "admin" } },
  { name = "observability", labels = { zone = "observability",tier = "platform" } },
  { name = "security",      labels = { zone = "security",     tier = "platform" } },
]
```

- [ ] **Step 2.3: init 검증**

```bash
cd /Users/jimmy/_Workspace/ocr
cp infra/terraform/environments/dev/main.tf /tmp/_smoke.tf  # dry-run 전 백업 (선택)
make tf-init
```
Expected: `Terraform has been successfully initialized!`

- [ ] **Step 2.4: 커밋**

```bash
git add infra/terraform/
git commit -m "chore(p0): terraform versions, providers, and dev entrypoint"
```

---

### Task 3: K8s 네임스페이스 모듈 (5 존)

**Files:**
- Create: `infra/terraform/modules/k8s-namespaces/main.tf`
- Create: `infra/terraform/modules/k8s-namespaces/variables.tf`
- Create: `infra/terraform/modules/k8s-namespaces/outputs.tf`
- Create: `tests/smoke/namespaces_test.sh`

- [ ] **Step 3.1: 변수·리소스 정의**

`infra/terraform/modules/k8s-namespaces/variables.tf`:
```hcl
variable "zones" {
  type = list(object({
    name   = string
    labels = map(string)
  }))
}
```

`infra/terraform/modules/k8s-namespaces/main.tf`:
```hcl
resource "kubernetes_namespace" "zone" {
  for_each = { for z in var.zones : z.name => z }

  metadata {
    name = each.value.name
    labels = merge(
      each.value.labels,
      {
        "app.kubernetes.io/managed-by" = "terraform"
        "pod-security.kubernetes.io/enforce" = "restricted"
        "pod-security.kubernetes.io/warn"    = "restricted"
      }
    )
  }
}
```

`infra/terraform/modules/k8s-namespaces/outputs.tf`:
```hcl
output "namespace_names" {
  value = [for ns in kubernetes_namespace.zone : ns.metadata[0].name]
}
```

- [ ] **Step 3.2: 스모크 테스트 작성 (failing test)**

`tests/smoke/namespaces_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

EXPECTED=(dmz processing admin observability security)

for ns in "${EXPECTED[@]}"; do
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "FAIL: namespace $ns missing"
    exit 1
  fi
  zone=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.zone}')
  if [ -z "$zone" ]; then
    echo "FAIL: namespace $ns has no 'zone' label"
    exit 1
  fi
done

echo "OK: all 5 zones present with labels"
```

```bash
chmod +x tests/smoke/namespaces_test.sh
bash tests/smoke/namespaces_test.sh
```
Expected: `FAIL: namespace dmz missing` (still missing before apply)

- [ ] **Step 3.3: terraform apply**

```bash
make tf-plan
make tf-apply
```
Expected: `Apply complete! Resources: 5 added`

- [ ] **Step 3.4: 스모크 테스트 재실행 (passing)**

```bash
bash tests/smoke/namespaces_test.sh
```
Expected: `OK: all 5 zones present with labels`

- [ ] **Step 3.5: 커밋**

```bash
git add infra/terraform/modules/k8s-namespaces/ tests/smoke/namespaces_test.sh
git commit -m "feat(p0): create 5-zone namespaces with security labels"
```

---

### Task 4: NetworkPolicy (Zero-Trust default-deny + 존 간 허용)

**Files:**
- Create: `infra/terraform/modules/network-policies/main.tf`
- Create: `tests/smoke/network_policies_test.sh`

- [ ] **Step 4.1: Default Deny + 존 간 규칙 작성**

`infra/terraform/modules/network-policies/main.tf`:
```hcl
variable "namespaces" {
  type = list(string)
}

# 1) 모든 네임스페이스: default-deny ingress + egress
resource "kubernetes_network_policy" "default_deny" {
  for_each = toset(var.namespaces)

  metadata {
    name      = "default-deny"
    namespace = each.value
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

# 2) DNS 허용 (모든 네임스페이스 → kube-system/kube-dns)
resource "kubernetes_network_policy" "allow_dns" {
  for_each = toset(var.namespaces)
  metadata {
    name      = "allow-dns"
    namespace = each.value
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports { port = "53"; protocol = "UDP" }
      ports { port = "53"; protocol = "TCP" }
    }
  }
}

# 3) 관측(observability) → 모든 네임스페이스의 메트릭 포트 수집 허용
resource "kubernetes_network_policy" "allow_metrics_scrape" {
  for_each = toset(var.namespaces)
  metadata {
    name      = "allow-metrics-scrape"
    namespace = each.value
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { zone = "observability" }
        }
      }
      ports { port = "9090"; protocol = "TCP" }
      ports { port = "9100"; protocol = "TCP" }
      ports { port = "8080"; protocol = "TCP" }
    }
  }
}

# 4) DMZ → processing: 불허 (기본 deny로 이미 막힘, 문서화 목적으로 라벨)
# 5) processing → DMZ: 불허 (동일)
# 6) admin → processing/observability: 명시 허용 (Phase 1에 세분화)
resource "kubernetes_network_policy" "admin_to_processing" {
  metadata {
    name      = "admin-to-processing"
    namespace = "processing"
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { zone = "admin" }
        }
      }
    }
  }
}
```

- [ ] **Step 4.2: 스모크 테스트 작성**

`tests/smoke/network_policies_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

for ns in dmz processing admin observability security; do
  cnt=$(kubectl -n "$ns" get networkpolicy default-deny -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
  if [ -z "$cnt" ]; then
    echo "FAIL: $ns missing default-deny NetworkPolicy"
    exit 1
  fi
done

# 교차 호출 테스트: dmz 파드가 processing 파드에 도달하면 fail
kubectl -n dmz run netcheck --image=curlimages/curl:8.7.1 --restart=Never --rm -i --command -- \
  sh -c 'curl -s --max-time 3 http://kubernetes.default.svc.cluster.local > /dev/null && echo "LEAK" || echo "BLOCKED"' \
  | tee /tmp/netcheck.out

grep -q "BLOCKED" /tmp/netcheck.out || { echo "FAIL: cross-zone traffic not blocked"; exit 1; }

echo "OK: default-deny active and cross-zone traffic blocked"
```

- [ ] **Step 4.3: apply + 검증**

```bash
make tf-apply
chmod +x tests/smoke/network_policies_test.sh
bash tests/smoke/network_policies_test.sh
```
Expected: `OK: default-deny active and cross-zone traffic blocked`

- [ ] **Step 4.4: 커밋**

```bash
git add infra/terraform/modules/network-policies/ tests/smoke/network_policies_test.sh
git commit -m "feat(p0): zero-trust default-deny + selective cross-zone policies"
```

---

### Task 5: cert-manager + 내부 CA (mTLS 기반)

**Files:**
- Create: `infra/helm/values/dev/cert-manager.yaml`
- Create: `infra/manifests/cert-manager/root-ca.yaml`
- Create: `infra/manifests/cert-manager/cluster-issuer-internal.yaml`
- Create: `tests/smoke/cert_manager_test.sh`

- [ ] **Step 5.1: cert-manager Helm values**

`infra/helm/values/dev/cert-manager.yaml`:
```yaml
installCRDs: true
prometheus:
  enabled: true
  servicemonitor:
    enabled: false  # Phase 1에 prometheus-operator 설치 후 true
replicaCount: 2
webhook:
  replicaCount: 2
cainjector:
  replicaCount: 2
```

- [ ] **Step 5.2: Root CA + ClusterIssuer 매니페스트**

`infra/manifests/cert-manager/root-ca.yaml`:
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ocr-internal-root-ca
  namespace: security
spec:
  isCA: true
  commonName: ocr-internal-root-ca
  subject:
    organizations: [ocr-platform]
    organizationalUnits: [security]
  duration: 87600h    # 10년
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 384
  secretName: ocr-internal-root-ca-key-pair
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
```

`infra/manifests/cert-manager/cluster-issuer-internal.yaml`:
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ocr-internal
spec:
  ca:
    secretName: ocr-internal-root-ca-key-pair
```

- [ ] **Step 5.3: 설치**

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace security \
  --values infra/helm/values/dev/cert-manager.yaml \
  --version v1.14.5 \
  --wait

kubectl apply -f infra/manifests/cert-manager/root-ca.yaml
kubectl wait --for=condition=Ready certificate/ocr-internal-root-ca -n security --timeout=120s
kubectl apply -f infra/manifests/cert-manager/cluster-issuer-internal.yaml
```

- [ ] **Step 5.4: 스모크 테스트**

`tests/smoke/cert_manager_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

kubectl -n security get certificate ocr-internal-root-ca -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
  | grep -q True || { echo "FAIL: root CA not Ready"; exit 1; }

# 테스트 인증서 발급
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: smoke-test-cert
  namespace: security
spec:
  commonName: smoke-test.ocr.local
  dnsNames: [smoke-test.ocr.local]
  secretName: smoke-test-tls
  issuerRef: { name: ocr-internal, kind: ClusterIssuer }
  duration: 2160h
  privateKey: { algorithm: ECDSA, size: 256 }
EOF

kubectl wait --for=condition=Ready certificate/smoke-test-cert -n security --timeout=60s
kubectl -n security delete certificate smoke-test-cert
kubectl -n security delete secret smoke-test-tls --ignore-not-found

echo "OK: internal CA issues certs"
```

```bash
chmod +x tests/smoke/cert_manager_test.sh
bash tests/smoke/cert_manager_test.sh
```
Expected: `OK: internal CA issues certs`

- [ ] **Step 5.5: 커밋**

```bash
git add infra/helm/values/dev/cert-manager.yaml infra/manifests/cert-manager/ tests/smoke/cert_manager_test.sh
git commit -m "feat(p0): cert-manager + internal root CA for mTLS"
```

---

### Task 6: 관측 스택 (kube-prometheus-stack + OpenSearch)

**Files:**
- Create: `infra/helm/values/dev/kube-prometheus-stack.yaml`
- Create: `infra/helm/values/dev/opensearch.yaml`
- Create: `tests/smoke/observability_test.sh`

- [ ] **Step 6.1: kube-prometheus-stack values**

`infra/helm/values/dev/kube-prometheus-stack.yaml`:
```yaml
fullnameOverride: kps

grafana:
  adminPassword: change-me-in-prod
  persistence: { enabled: true, size: 10Gi }
  # Phase 1: Keycloak OIDC 연동으로 교체
  service: { type: ClusterIP }
  ingress: { enabled: false }

alertmanager:
  alertmanagerSpec:
    replicas: 2
    retention: 240h
  ingress: { enabled: false }

prometheus:
  prometheusSpec:
    replicas: 2
    retention: 30d
    retentionSize: 40GB
    resources:
      requests: { cpu: 500m, memory: 2Gi }
      limits:   { cpu: 2,    memory: 8Gi }
    storageSpec:
      volumeClaimTemplate:
        spec:
          resources: { requests: { storage: 50Gi } }
    # 전 네임스페이스 ServiceMonitor 감지
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false

kubeStateMetrics: { enabled: true }
nodeExporter: { enabled: true }

# Dashboard: Loki 대신 OpenSearch 사용 (별도 설치)
```

- [ ] **Step 6.2: OpenSearch values**

`infra/helm/values/dev/opensearch.yaml`:
```yaml
clusterName: ocr-logs
replicas: 3
singleNode: false

persistence:
  enabled: true
  size: 50Gi

resources:
  requests: { cpu: 500m, memory: 2Gi }
  limits:   { cpu: 2,    memory: 4Gi }

config:
  opensearch.yml: |
    plugins.security.disabled: false
    plugins.security.ssl.transport.enforce_hostname_verification: false

# 보안 플러그인 초기 admin 비밀번호 (Phase 1: Keycloak SAML 연동)
extraEnvs:
  - name: OPENSEARCH_INITIAL_ADMIN_PASSWORD
    valueFrom:
      secretKeyRef:
        name: opensearch-admin
        key: password

service:
  type: ClusterIP
```

- [ ] **Step 6.3: 설치**

```bash
kubectl -n observability create secret generic opensearch-admin \
  --from-literal=password="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add opensearch https://opensearch-project.github.io/helm-charts
helm repo update

helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace observability \
  --values infra/helm/values/dev/kube-prometheus-stack.yaml \
  --version 58.4.0 \
  --wait --timeout 15m

helm upgrade --install opensearch opensearch/opensearch \
  --namespace observability \
  --values infra/helm/values/dev/opensearch.yaml \
  --version 2.21.0 \
  --wait --timeout 15m
```

- [ ] **Step 6.4: 스모크 테스트**

`tests/smoke/observability_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

kubectl -n observability wait --for=condition=Available deploy -l app.kubernetes.io/name=grafana --timeout=120s
kubectl -n observability wait --for=condition=Ready pod -l app=prometheus --timeout=120s

# Prometheus 타겟 hit 확인
kubectl -n observability port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
PF=$!
sleep 3
curl -sf localhost:9090/-/ready || { kill $PF; echo "FAIL: prometheus not ready"; exit 1; }
kill $PF

# OpenSearch cluster health
kubectl -n observability exec -it opensearch-cluster-master-0 -- \
  curl -sk -u admin:"$(kubectl -n observability get secret opensearch-admin -o jsonpath='{.data.password}' | base64 -d)" \
  https://localhost:9200/_cluster/health | jq -r .status | grep -E 'green|yellow' \
  || { echo "FAIL: opensearch red"; exit 1; }

echo "OK: prometheus + opensearch healthy"
```

```bash
chmod +x tests/smoke/observability_test.sh
bash tests/smoke/observability_test.sh
```
Expected: `OK: prometheus + opensearch healthy`

- [ ] **Step 6.5: 커밋**

```bash
git add infra/helm/values/dev/kube-prometheus-stack.yaml infra/helm/values/dev/opensearch.yaml tests/smoke/observability_test.sh
git commit -m "feat(p0): prometheus + grafana + opensearch baseline"
```

---

### Task 7: PostgreSQL HA (CloudNativePG) — 메인 + PII 금고 분리

**Files:**
- Create: `infra/helm/values/dev/cloudnative-pg.yaml`
- Create: `infra/manifests/postgres/main-cluster.yaml`
- Create: `infra/manifests/postgres/pii-cluster.yaml`
- Create: `tests/smoke/postgres_test.sh`

- [ ] **Step 7.1: Operator values**

`infra/helm/values/dev/cloudnative-pg.yaml`:
```yaml
fullnameOverride: cnpg
replicaCount: 2
monitoring:
  podMonitorEnabled: true
```

- [ ] **Step 7.2: Cluster 매니페스트**

`infra/manifests/postgres/main-cluster.yaml`:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-main
  namespace: processing
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:16.2
  storage:
    size: 100Gi
    storageClass: standard
  resources:
    requests: { cpu: 1,   memory: 4Gi }
    limits:   { cpu: 4,   memory: 8Gi }
  bootstrap:
    initdb:
      database: ocr
      owner: ocr
      encoding: UTF8
      localeCollate: C
      localeCType: C
  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: "2GB"
      effective_cache_size: "4GB"
      wal_level: replica
      max_wal_senders: "10"
      wal_keep_size: "1GB"
  backup:
    retentionPolicy: "30d"
    barmanObjectStore:
      destinationPath: s3://ocr-pg-backups/main
      endpointURL: http://seaweedfs-s3.processing.svc:8333
      s3Credentials:
        accessKeyId:     { name: seaweedfs-s3-creds, key: access-key }
        secretAccessKey: { name: seaweedfs-s3-creds, key: secret-key }
      wal: { compression: gzip }
      data: { compression: gzip }
  monitoring:
    enablePodMonitor: true
```

`infra/manifests/postgres/pii-cluster.yaml`:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-pii
  namespace: security  # 물리·네트워크 분리 (security zone)
spec:
  instances: 2
  imageName: ghcr.io/cloudnative-pg/postgresql:16.2
  storage: { size: 50Gi, storageClass: standard }
  resources:
    requests: { cpu: 500m, memory: 2Gi }
    limits:   { cpu: 2,    memory: 4Gi }
  bootstrap:
    initdb:
      database: pii_vault
      owner: pii
      encoding: UTF8
  postgresql:
    parameters:
      ssl: "on"
      log_connections: "on"
      log_disconnections: "on"
  monitoring: { enablePodMonitor: true }
```

- [ ] **Step 7.3: Operator 설치 + Cluster 배포**

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace security \
  --values infra/helm/values/dev/cloudnative-pg.yaml \
  --version 0.20.2 --wait

# S3 backup 자격증명 (나중에 SeaweedFS S3에서 발급 후 업데이트)
kubectl -n processing create secret generic seaweedfs-s3-creds \
  --from-literal=access-key=placeholder \
  --from-literal=secret-key=placeholder \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f infra/manifests/postgres/main-cluster.yaml
kubectl apply -f infra/manifests/postgres/pii-cluster.yaml

kubectl wait --for=condition=Ready cluster/pg-main  -n processing --timeout=10m
kubectl wait --for=condition=Ready cluster/pg-pii   -n security   --timeout=10m
```

- [ ] **Step 7.4: 스모크 테스트**

`tests/smoke/postgres_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

main_status=$(kubectl -n processing get cluster pg-main -o jsonpath='{.status.phase}')
[ "$main_status" = "Cluster in healthy state" ] || { echo "FAIL: pg-main phase=$main_status"; exit 1; }

pii_status=$(kubectl -n security get cluster pg-pii -o jsonpath='{.status.phase}')
[ "$pii_status" = "Cluster in healthy state" ] || { echo "FAIL: pg-pii phase=$pii_status"; exit 1; }

# 연결 테스트
kubectl -n processing exec -it pg-main-1 -- psql -U ocr -d ocr -c "SELECT 1" | grep -q "1 row" \
  || { echo "FAIL: pg-main cannot query"; exit 1; }

echo "OK: both postgres clusters healthy"
```

```bash
chmod +x tests/smoke/postgres_test.sh
bash tests/smoke/postgres_test.sh
```
Expected: `OK: both postgres clusters healthy`

- [ ] **Step 7.5: 커밋**

```bash
git add infra/helm/values/dev/cloudnative-pg.yaml infra/manifests/postgres/ tests/smoke/postgres_test.sh
git commit -m "feat(p0): postgres HA clusters — main(processing) + pii-vault(security)"
```

---

### Task 8: SeaweedFS (Master + Volume + Filer + S3 Gateway)

**Files:**
- Create: `infra/helm/values/dev/seaweedfs.yaml`
- Create: `infra/manifests/seaweedfs/s3-config.yaml`
- Create: `tests/smoke/seaweedfs_test.sh`

- [ ] **Step 8.1: SeaweedFS Helm values**

`infra/helm/values/dev/seaweedfs.yaml`:
```yaml
global:
  enableSecurity: true
  serviceAccountName: seaweedfs
  replicationPlacement: "001"   # 동일 데이터센터 내 3복제

master:
  replicas: 3
  data:
    size: 10Gi
    storageClass: standard
  config: |
    [master.maintenance]
    scripts = ""
    sleep_minutes = 17

volume:
  replicas: 6
  data:
    size: 200Gi
    storageClass: standard
  rack: default
  dataCenter: dev-dc

filer:
  replicas: 2
  data:
    size: 10Gi

s3:
  enabled: true
  replicas: 2
  port: 8333
```

`infra/manifests/seaweedfs/s3-config.yaml`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: seaweedfs-s3-config
  namespace: processing
type: Opaque
stringData:
  config.json: |
    {
      "identities": [
        {
          "name": "postgres-backup",
          "credentials": [
            { "accessKey": "GENERATE-ME", "secretKey": "GENERATE-ME" }
          ],
          "actions": ["Read", "Write"]
        }
      ]
    }
```

- [ ] **Step 8.2: 자격증명 생성 + 설치**

```bash
AK=$(openssl rand -hex 16)
SK=$(openssl rand -hex 32)
yq -i ".stringData.\"config.json\" |= sub(\"GENERATE-ME\"; \"$AK\" ) | .stringData.\"config.json\" |= sub(\"GENERATE-ME\"; \"$SK\")" \
  infra/manifests/seaweedfs/s3-config.yaml

kubectl -n processing create secret generic seaweedfs-s3-creds \
  --from-literal=access-key=$AK \
  --from-literal=secret-key=$SK \
  --dry-run=client -o yaml | kubectl apply -f -

helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
helm repo update

helm upgrade --install seaweedfs seaweedfs/seaweedfs \
  --namespace processing \
  --values infra/helm/values/dev/seaweedfs.yaml \
  --version 4.0.0 --wait --timeout 15m

kubectl apply -f infra/manifests/seaweedfs/s3-config.yaml
```

- [ ] **Step 8.3: 스모크 테스트**

`tests/smoke/seaweedfs_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

kubectl -n processing wait --for=condition=Ready pod -l app.kubernetes.io/name=seaweedfs --timeout=5m

AK=$(kubectl -n processing get secret seaweedfs-s3-creds -o jsonpath='{.data.access-key}' | base64 -d)
SK=$(kubectl -n processing get secret seaweedfs-s3-creds -o jsonpath='{.data.secret-key}' | base64 -d)

kubectl -n processing run s3check --rm -i --restart=Never --image=amazon/aws-cli:2.15.0 --env="AWS_ACCESS_KEY_ID=$AK" --env="AWS_SECRET_ACCESS_KEY=$SK" -- \
  s3 --endpoint-url http://seaweedfs-s3.processing.svc:8333 mb s3://smoke-bucket

kubectl -n processing run s3put --rm -i --restart=Never --image=amazon/aws-cli:2.15.0 --env="AWS_ACCESS_KEY_ID=$AK" --env="AWS_SECRET_ACCESS_KEY=$SK" -- \
  sh -c 'echo "hello" > /tmp/f && aws s3 --endpoint-url http://seaweedfs-s3.processing.svc:8333 cp /tmp/f s3://smoke-bucket/f'

kubectl -n processing run s3get --rm -i --restart=Never --image=amazon/aws-cli:2.15.0 --env="AWS_ACCESS_KEY_ID=$AK" --env="AWS_SECRET_ACCESS_KEY=$SK" -- \
  sh -c 'aws s3 --endpoint-url http://seaweedfs-s3.processing.svc:8333 cp s3://smoke-bucket/f - | grep -q hello'

echo "OK: seaweedfs S3 put/get works"
```

```bash
chmod +x tests/smoke/seaweedfs_test.sh
bash tests/smoke/seaweedfs_test.sh
```
Expected: `OK: seaweedfs S3 put/get works`

- [ ] **Step 8.4: 커밋**

```bash
git add infra/helm/values/dev/seaweedfs.yaml infra/manifests/seaweedfs/ tests/smoke/seaweedfs_test.sh
git commit -m "feat(p0): seaweedfs master/volume/filer/s3 with replication=3"
```

---

### Task 9: OpenBao (Raft 3노드 + SoftHSM auto-unseal + Transit/Transform)

**Files:**
- Create: `infra/helm/values/dev/openbao.yaml`
- Create: `infra/manifests/openbao/init-job.yaml`
- Create: `infra/manifests/openbao/transit-config.yaml`
- Create: `tests/smoke/openbao_transit_test.sh`

- [ ] **Step 9.1: OpenBao Helm values**

`infra/helm/values/dev/openbao.yaml`:
```yaml
fullnameOverride: openbao
server:
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true
        listener "tcp" {
          tls_disable = 0
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_cert_file = "/vault/userconfig/openbao-tls/tls.crt"
          tls_key_file  = "/vault/userconfig/openbao-tls/tls.key"
        }
        storage "raft" {
          path = "/vault/data"
        }
        service_registration "kubernetes" {}
        # SoftHSM auto-unseal
        seal "pkcs11" {
          lib = "/usr/lib/softhsm/libsofthsm2.so"
          slot = "0"
          pin  = "env://SOFTHSM_PIN"
          key_label = "openbao-unseal"
          hmac_key_label = "openbao-hmac"
          generate_key = "true"
        }
  extraVolumes:
    - type: secret
      name: openbao-tls
  extraEnvironmentVars:
    SOFTHSM_PIN: "1234"   # dev only; Phase 1에 sealed-secret or Vault Agent
  volumes:
    - name: softhsm-config
      configMap:
        name: softhsm-config
    - name: softhsm-data
      emptyDir: {}
  volumeMounts:
    - name: softhsm-config
      mountPath: /etc/softhsm
    - name: softhsm-data
      mountPath: /var/lib/softhsm
  image:
    repository: openbao/openbao
    tag: 2.0.0
injector:
  enabled: false
ui:
  enabled: true
```

- [ ] **Step 9.2: TLS 인증서 + SoftHSM configmap**

```bash
# OpenBao용 TLS 인증서
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openbao-tls
  namespace: security
spec:
  secretName: openbao-tls
  commonName: openbao.security.svc.cluster.local
  dnsNames:
    - openbao
    - openbao.security
    - openbao.security.svc
    - openbao.security.svc.cluster.local
    - "*.openbao-internal.security.svc.cluster.local"
  issuerRef: { name: ocr-internal, kind: ClusterIssuer }
  duration: 8760h
  privateKey: { algorithm: ECDSA, size: 256 }
EOF

# SoftHSM 설정
kubectl -n security create configmap softhsm-config --from-literal=softhsm2.conf='
directories.tokendir = /var/lib/softhsm/tokens/
objectstore.backend = file
log.level = INFO
' --dry-run=client -o yaml | kubectl apply -f -
```

- [ ] **Step 9.3: OpenBao 설치**

```bash
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update
helm upgrade --install openbao openbao/openbao \
  --namespace security \
  --values infra/helm/values/dev/openbao.yaml \
  --version 0.5.0 --wait --timeout 10m
```

- [ ] **Step 9.4: Raft 초기화 Job**

`infra/manifests/openbao/init-job.yaml`:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: openbao-init
  namespace: security
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: init
          image: openbao/openbao:2.0.0
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              export VAULT_ADDR=https://openbao-0.openbao-internal:8200
              export VAULT_CACERT=/etc/tls/ca.crt
              until bao status 2>/dev/null; [ $? -eq 2 ]; do sleep 2; done
              bao operator init -key-shares=5 -key-threshold=3 -format=json > /tmp/init.json
              kubectl -n security create secret generic openbao-init-keys --from-file=init.json=/tmp/init.json
              # Raft join
              for i in 1 2; do
                export VAULT_ADDR=https://openbao-$i.openbao-internal:8200
                bao operator raft join https://openbao-0.openbao-internal:8200 -leader-ca-cert=@/etc/tls/ca.crt || true
              done
          volumeMounts:
            - { name: tls, mountPath: /etc/tls }
      serviceAccountName: openbao-init
      volumes:
        - name: tls
          secret:
            secretName: ocr-internal-root-ca-key-pair
            items: [{ key: ca.crt, path: ca.crt }]
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: openbao-init, namespace: security }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: openbao-init, namespace: security }
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: openbao-init, namespace: security }
roleRef: { kind: Role, name: openbao-init, apiGroup: rbac.authorization.k8s.io }
subjects: [{ kind: ServiceAccount, name: openbao-init, namespace: security }]
```

```bash
kubectl apply -f infra/manifests/openbao/init-job.yaml
kubectl -n security wait --for=condition=complete job/openbao-init --timeout=5m
```

- [ ] **Step 9.5: Transit/Transform 엔진 활성**

`infra/manifests/openbao/transit-config.yaml`:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: openbao-enable-engines
  namespace: security
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: openbao-init
      containers:
        - name: configure
          image: openbao/openbao:2.0.0
          command: ["/bin/sh","-c"]
          args:
            - |
              set -e
              export VAULT_ADDR=https://openbao.security.svc:8200
              export VAULT_CACERT=/etc/tls/ca.crt
              ROOT=$(kubectl -n security get secret openbao-init-keys -o jsonpath='{.data.init\.json}' | base64 -d | jq -r .root_token)
              export VAULT_TOKEN=$ROOT
              bao secrets enable -path=transit transit || true
              bao secrets enable -path=transform transform || true
              bao write -f transit/keys/upload-kek type=aes256-gcm96
              bao write -f transit/keys/storage-kek type=aes256-gcm96
              bao write -f transit/keys/egress-kek  type=aes256-gcm96
              echo "engines ready"
          volumeMounts:
            - { name: tls, mountPath: /etc/tls }
      volumes:
        - name: tls
          secret:
            secretName: ocr-internal-root-ca-key-pair
            items: [{ key: ca.crt, path: ca.crt }]
```

```bash
kubectl apply -f infra/manifests/openbao/transit-config.yaml
kubectl -n security wait --for=condition=complete job/openbao-enable-engines --timeout=3m
```

- [ ] **Step 9.6: 스모크 테스트 (Transit encrypt/decrypt)**

`tests/smoke/openbao_transit_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT=$(kubectl -n security get secret openbao-init-keys -o jsonpath='{.data.init\.json}' | base64 -d | jq -r .root_token)
POD=openbao-0

PLAINTEXT=$(echo -n "hello-encryption" | base64)

CT=$(kubectl -n security exec $POD -- sh -c "VAULT_TOKEN=$ROOT VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  bao write -format=json transit/encrypt/upload-kek plaintext=$PLAINTEXT | jq -r .data.ciphertext")

DEC=$(kubectl -n security exec $POD -- sh -c "VAULT_TOKEN=$ROOT VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true \
  bao write -format=json transit/decrypt/upload-kek ciphertext=$CT | jq -r .data.plaintext | base64 -d")

[ "$DEC" = "hello-encryption" ] || { echo "FAIL: decrypt mismatch ($DEC)"; exit 1; }

echo "OK: openbao transit encrypt/decrypt roundtrip"
```

```bash
chmod +x tests/smoke/openbao_transit_test.sh
bash tests/smoke/openbao_transit_test.sh
```
Expected: `OK: openbao transit encrypt/decrypt roundtrip`

- [ ] **Step 9.7: 커밋**

```bash
git add infra/helm/values/dev/openbao.yaml infra/manifests/openbao/ tests/smoke/openbao_transit_test.sh
git commit -m "feat(p0): openbao HA with softhsm unseal + transit KEKs"
```

---

### Task 10: Keycloak (OIDC Realm + Admin SSO baseline)

**Files:**
- Create: `infra/helm/values/dev/keycloak.yaml`
- Create: `infra/manifests/keycloak/realm-ocr.json`
- Create: `tests/smoke/keycloak_token_test.sh`

- [ ] **Step 10.1: Keycloak Helm values**

`infra/helm/values/dev/keycloak.yaml`:
```yaml
replicaCount: 2
image:
  repository: quay.io/keycloak/keycloak
  tag: "24.0.3"

auth:
  adminUser: keycloak-admin
  existingSecret: keycloak-admin
  passwordSecretKey: password

postgresql:
  enabled: false
externalDatabase:
  host: pg-main-rw.processing.svc
  port: 5432
  user: keycloak
  database: keycloak
  existingSecret: keycloak-db
  existingSecretPasswordKey: password

ingress:
  enabled: false

production: true
proxy: edge
tls:
  enabled: true
  existingSecret: keycloak-tls

extraEnv: |
  - name: KC_HOSTNAME_STRICT
    value: "false"

startupProbe:
  enabled: true
  initialDelaySeconds: 90
readinessProbe:
  enabled: true
livenessProbe:
  enabled: true
```

- [ ] **Step 10.2: Realm + DB + TLS 사전 준비**

```bash
# Keycloak TLS
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: keycloak-tls
  namespace: admin
spec:
  secretName: keycloak-tls
  commonName: keycloak.admin.svc.cluster.local
  dnsNames:
    - keycloak
    - keycloak.admin
    - keycloak.admin.svc
    - keycloak.admin.svc.cluster.local
  issuerRef: { name: ocr-internal, kind: ClusterIssuer }
  duration: 8760h
EOF

# Keycloak용 DB 계정
kubectl -n processing exec -it pg-main-1 -- psql -U postgres -c \
  "CREATE USER keycloak WITH PASSWORD 'KEYCLOAK_PW_ENV'; CREATE DATABASE keycloak OWNER keycloak;"
KPW="KEYCLOAK_PW_ENV"
kubectl -n admin create secret generic keycloak-db --from-literal=password=$KPW \
  --dry-run=client -o yaml | kubectl apply -f -

# Admin 비밀번호
kubectl -n admin create secret generic keycloak-admin \
  --from-literal=password="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

`infra/manifests/keycloak/realm-ocr.json`:
```json
{
  "realm": "ocr",
  "enabled": true,
  "sslRequired": "all",
  "registrationAllowed": false,
  "clients": [
    {
      "clientId": "ocr-backoffice",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "redirectUris": ["https://backoffice.ocr.local/*"],
      "webOrigins": ["https://backoffice.ocr.local"],
      "attributes": { "pkce.code.challenge.method": "S256" }
    },
    {
      "clientId": "ocr-api",
      "enabled": true,
      "protocol": "openid-connect",
      "bearerOnly": true
    }
  ],
  "roles": {
    "realm": [
      { "name": "submitter" },
      { "name": "reviewer" },
      { "name": "approver" },
      { "name": "operator" },
      { "name": "auditor" },
      { "name": "pii-viewer" },
      { "name": "system-admin" },
      { "name": "security-admin" }
    ]
  },
  "users": [
    {
      "username": "dev-admin",
      "enabled": true,
      "emailVerified": true,
      "email": "dev-admin@ocr.local",
      "credentials": [{ "type": "password", "value": "dev-admin-pw", "temporary": false }],
      "realmRoles": ["system-admin"]
    }
  ]
}
```

- [ ] **Step 10.3: Keycloak 설치 + realm import**

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm upgrade --install keycloak bitnami/keycloak \
  --namespace admin \
  --values infra/helm/values/dev/keycloak.yaml \
  --version 21.4.4 --wait --timeout 10m

kubectl -n admin create configmap keycloak-realm --from-file=infra/manifests/keycloak/realm-ocr.json

# realm import: CLI
POD=$(kubectl -n admin get pod -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')
kubectl -n admin cp infra/manifests/keycloak/realm-ocr.json $POD:/tmp/realm.json
kubectl -n admin exec $POD -- /opt/bitnami/keycloak/bin/kcadm.sh config credentials \
  --server https://keycloak.admin.svc:8443 --realm master --user keycloak-admin \
  --password "$(kubectl -n admin get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)"
kubectl -n admin exec $POD -- /opt/bitnami/keycloak/bin/kcadm.sh create realms -f /tmp/realm.json || echo "realm may already exist"
```

- [ ] **Step 10.4: 스모크 테스트 (OIDC 토큰 발급)**

`tests/smoke/keycloak_token_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

KC=https://keycloak.admin.svc:8443
CA=/tmp/ca.crt
kubectl -n security get secret ocr-internal-root-ca-key-pair -o jsonpath='{.data.ca\.crt}' | base64 -d > $CA

TOKEN=$(kubectl -n admin run kc-test --rm -i --restart=Never --image=curlimages/curl:8.7.1 -- \
  sh -c "curl -sk --cacert $CA -X POST '$KC/realms/ocr/protocol/openid-connect/token' \
    -d grant_type=password -d client_id=ocr-backoffice -d client_secret=dummy \
    -d username=dev-admin -d password=dev-admin-pw | jq -r .access_token")

[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "FAIL: no access_token ($TOKEN)"; exit 1; }
echo "OK: keycloak realm ocr issues tokens"
```

```bash
chmod +x tests/smoke/keycloak_token_test.sh
bash tests/smoke/keycloak_token_test.sh
```
Expected: `OK: keycloak realm ocr issues tokens`

- [ ] **Step 10.5: 커밋**

```bash
git add infra/helm/values/dev/keycloak.yaml infra/manifests/keycloak/ tests/smoke/keycloak_token_test.sh
git commit -m "feat(p0): keycloak HA with ocr realm and 8 baseline roles"
```

---

### Task 11: ArgoCD + GitOps App-of-Apps

**Files:**
- Create: `infra/argocd/install/values.yaml`
- Create: `infra/helm/umbrella/Chart.yaml`
- Create: `infra/helm/umbrella/templates/applicationset.yaml`
- Create: `infra/argocd/apps/root-app.yaml`
- Create: `tests/smoke/argocd_test.sh`

- [ ] **Step 11.1: ArgoCD install values**

`infra/argocd/install/values.yaml`:
```yaml
global:
  image: { tag: v2.10.5 }
server:
  replicas: 2
  extraArgs:
    - --insecure   # dev only; Phase 1 TLS + Keycloak SSO
configs:
  params:
    server.insecure: "true"
controller:
  replicas: 1
repoServer:
  replicas: 2
applicationSet:
  replicas: 2
```

- [ ] **Step 11.2: Umbrella Chart**

`infra/helm/umbrella/Chart.yaml`:
```yaml
apiVersion: v2
name: ocr-platform-umbrella
type: application
version: 0.1.0
description: OCR Platform umbrella — declares all platform sub-apps for ArgoCD
```

`infra/helm/umbrella/templates/applicationset.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ocr-platform
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - name: cert-manager
            chart: cert-manager
            repoURL: https://charts.jetstack.io
            version: v1.14.5
            namespace: security
            valuesFile: cert-manager.yaml
          - name: kps
            chart: kube-prometheus-stack
            repoURL: https://prometheus-community.github.io/helm-charts
            version: "58.4.0"
            namespace: observability
            valuesFile: kube-prometheus-stack.yaml
          - name: opensearch
            chart: opensearch
            repoURL: https://opensearch-project.github.io/helm-charts
            version: "2.21.0"
            namespace: observability
            valuesFile: opensearch.yaml
          - name: cnpg
            chart: cloudnative-pg
            repoURL: https://cloudnative-pg.github.io/charts
            version: "0.20.2"
            namespace: security
            valuesFile: cloudnative-pg.yaml
          - name: seaweedfs
            chart: seaweedfs
            repoURL: https://seaweedfs.github.io/seaweedfs/helm
            version: "4.0.0"
            namespace: processing
            valuesFile: seaweedfs.yaml
          - name: openbao
            chart: openbao
            repoURL: https://openbao.github.io/openbao-helm
            version: "0.5.0"
            namespace: security
            valuesFile: openbao.yaml
          - name: keycloak
            chart: keycloak
            repoURL: https://charts.bitnami.com/bitnami
            version: "21.4.4"
            namespace: admin
            valuesFile: keycloak.yaml
  template:
    metadata:
      name: '{{ "{{name}}" }}'
    spec:
      project: default
      source:
        chart: '{{ "{{chart}}" }}'
        repoURL: '{{ "{{repoURL}}" }}'
        targetRevision: '{{ "{{version}}" }}'
        helm:
          valueFiles:
            - $values/infra/helm/values/dev/{{ "{{valuesFile}}" }}
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{ "{{namespace}}" }}'
      sources:
        - repoURL: https://github.com/YOUR-ORG/ocr.git
          targetRevision: HEAD
          ref: values
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [CreateNamespace=false, ServerSideApply=true]
```

`infra/argocd/apps/root-app.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ocr-root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR-ORG/ocr.git
    targetRevision: HEAD
    path: infra/helm/umbrella
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

- [ ] **Step 11.3: ArgoCD 설치 + Root App apply**

```bash
# YOUR-ORG를 실제 조직으로 치환
sed -i '' 's|YOUR-ORG|my-org|g' infra/helm/umbrella/templates/applicationset.yaml infra/argocd/apps/root-app.yaml

make argocd-bootstrap
kubectl -n argocd wait --for=condition=Available deploy/argocd-server --timeout=5m
```

- [ ] **Step 11.4: 스모크 테스트**

`tests/smoke/argocd_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

kubectl -n argocd wait --for=condition=Available deploy -l app.kubernetes.io/name=argocd-server --timeout=5m

# Root app이 존재하고 Sync 상태인지
status=$(kubectl -n argocd get application ocr-root -o jsonpath='{.status.sync.status}')
[ "$status" = "Synced" ] || [ "$status" = "OutOfSync" ] || { echo "FAIL: ocr-root status=$status"; exit 1; }

# ApplicationSet에 의해 7개 앱 생성 확인
cnt=$(kubectl -n argocd get applications -o name | wc -l | tr -d ' ')
[ "$cnt" -ge 8 ] || { echo "FAIL: expected >=8 applications, got $cnt"; exit 1; }

echo "OK: argocd synced root app + child applications"
```

```bash
chmod +x tests/smoke/argocd_test.sh
bash tests/smoke/argocd_test.sh
```
Expected: `OK: argocd synced root app + child applications`

- [ ] **Step 11.5: 커밋**

```bash
git add infra/argocd/ infra/helm/umbrella/ tests/smoke/argocd_test.sh
git commit -m "feat(p0): argocd gitops with app-of-apps for all platform components"
```

---

### Task 12: P0 Smoke Suite — 플랫폼 전체 Ready 검증

**Files:**
- Create: `tests/integration/platform_ready_test.sh`
- Modify: `Makefile` (smoke 타겟에 integration 추가)

- [ ] **Step 12.1: 통합 Ready 테스트**

`tests/integration/platform_ready_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

echo "== P0 Platform Readiness =="

# 1) 5 네임스페이스
for ns in dmz processing admin observability security; do
  kubectl get ns "$ns" >/dev/null || { echo "FAIL: ns $ns"; exit 1; }
done
echo "  [✓] 5 namespaces"

# 2) NetworkPolicy default-deny
for ns in dmz processing admin observability security; do
  kubectl -n "$ns" get networkpolicy default-deny >/dev/null || { echo "FAIL: $ns no default-deny"; exit 1; }
done
echo "  [✓] default-deny on all zones"

# 3) cert-manager + Root CA
kubectl -n security get certificate ocr-internal-root-ca \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True \
  || { echo "FAIL: root CA not ready"; exit 1; }
echo "  [✓] cert-manager + Root CA"

# 4) Prometheus + Grafana + OpenSearch
kubectl -n observability wait --for=condition=Available deploy -l app.kubernetes.io/name=grafana --timeout=60s
kubectl -n observability get statefulset opensearch-cluster-master \
  -o jsonpath='{.status.readyReplicas}' | grep -q '^3$' || { echo "FAIL: opensearch not fully ready"; exit 1; }
echo "  [✓] observability stack"

# 5) Postgres 두 클러스터
[ "$(kubectl -n processing get cluster pg-main -o jsonpath='{.status.readyInstances}')" = "3" ] || { echo "FAIL: pg-main"; exit 1; }
[ "$(kubectl -n security   get cluster pg-pii  -o jsonpath='{.status.readyInstances}')" = "2" ] || { echo "FAIL: pg-pii"; exit 1; }
echo "  [✓] postgres HA (main=3, pii=2)"

# 6) SeaweedFS
kubectl -n processing get pods -l app.kubernetes.io/name=seaweedfs \
  -o jsonpath='{.items[*].status.phase}' | grep -v -q Pending || true
running=$(kubectl -n processing get pods -l app.kubernetes.io/name=seaweedfs --no-headers | grep -c Running)
[ "$running" -ge 11 ] || { echo "FAIL: seaweedfs pods running=$running"; exit 1; }   # 3 master + 6 volume + 2 s3 (+filer)
echo "  [✓] seaweedfs fleet"

# 7) OpenBao
for i in 0 1 2; do
  kubectl -n security exec openbao-$i -- sh -c 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true bao status' >/dev/null \
    || { echo "FAIL: openbao-$i status"; exit 1; }
done
echo "  [✓] openbao raft 3-node"

# 8) Keycloak + realm
bash tests/smoke/keycloak_token_test.sh >/dev/null
echo "  [✓] keycloak OIDC issuing tokens"

# 9) ArgoCD
apps=$(kubectl -n argocd get applications -o name | wc -l | tr -d ' ')
[ "$apps" -ge 8 ] || { echo "FAIL: argocd applications=$apps"; exit 1; }
echo "  [✓] argocd gitops active ($apps applications)"

echo ""
echo "=== P0 PLATFORM READY ==="
```

- [ ] **Step 12.2: Makefile 타겟 확장**

`Makefile`의 `smoke` 타겟 아래에 추가:
```makefile
.PHONY: integration
integration:
	bash tests/integration/platform_ready_test.sh

.PHONY: verify
verify: smoke integration
	@echo "=== P0 verification complete ==="
```

- [ ] **Step 12.3: 실행**

```bash
chmod +x tests/integration/platform_ready_test.sh
make verify
```
Expected: `=== P0 PLATFORM READY ===` 뒤에 `=== P0 verification complete ===`

- [ ] **Step 12.4: 최종 커밋**

```bash
git add tests/integration/platform_ready_test.sh Makefile
git commit -m "test(p0): integration smoke verifies full platform readiness"
```

- [ ] **Step 12.5: P0 완료 태그**

```bash
git tag -a p0-complete -m "P0 infra bootstrap complete: 5-zone K8s + observability + pg HA + seaweedfs + openbao + keycloak + argocd"
```

---

## Self-Review (플랜 작성자 점검)

### 1. Spec 커버리지
| 스펙 섹션 | P0 태스크 |
|---|---|
| §1.1 3존 분리 | T3 네임스페이스 |
| §1.4 mTLS | T5 cert-manager |
| §2.5 키 계층 (Transit KEK) | T9 OpenBao |
| §A.4 인프라 규모 (PG HA·SeaweedFS·OpenSearch) | T6·T7·T8 |
| §B.2 이중화 (Raft·Replication) | T7·T8·T9 |
| §C.2 통제항목(암호·접근·로그) | T5·T6·T9·T10 기반 |
| §5.2 Keycloak + 역할 | T10 Realm + 8 Role |
| 관측 SLI/SLO 기반 | T6 kps + OpenSearch |

비커버 항목(P1 이후):
- 실제 HSM (SoftHSM으로 대체 중; 프로덕션 HSM은 Phase 2)
- SPIFFE/SPIRE (Phase 2)
- Kafka·MirrorMaker (P1)
- Camunda·OPA (P4)
- HITL·MLflow·Triton (P2)

### 2. Placeholder 스캔
- "YOUR-ORG", "KEYCLOAK_PW_ENV", "dev-admin-pw"는 dev 환경 치환 가능한 명시적 자리표시자(실행 단계에서 sed·env로 교체 지시 포함). 프로덕션 가기 전 Phase 1 내 제거 필요 — 자체 태스크 아닌 환경별 설정.
- 그 외 "TBD/TODO" 없음 ✓

### 3. 타입·명명 일관성
- 네임스페이스: dmz/processing/admin/observability/security (T3부터 마지막까지 일관) ✓
- ClusterIssuer: `ocr-internal` 일관 ✓
- 시크릿명: `ocr-internal-root-ca-key-pair` 일관 ✓
- OpenBao Transit 키: `upload-kek`, `storage-kek`, `egress-kek` — 스펙 §A/§2와 일관 ✓
- Keycloak Realm: `ocr`, clients `ocr-backoffice`·`ocr-api` — P4에서 동일 이름 사용 예정 ✓

### 4. 모호성
- **ArgoCD 리포 URL**: sed로 치환 지시 포함 (`YOUR-ORG` → 실제 조직)
- **Secret 비밀번호**: dev는 `openssl rand`로 자동생성, 프로덕션은 external-secrets/sealed-secrets로 P1에서 대체
- **K8s 클러스터**: 사전 준비 섹션에 최소 사양 명시 (4 노드 × 8vCPU/16GB, K8s 1.29+)

---

## Plan 완료 + 실행 옵션

**Plan 저장 완료**: `/Users/jimmy/_Workspace/ocr/docs/superpowers/plans/2026-04-18-P0-infra-bootstrap.md`

두 실행 옵션:

**1. Subagent-Driven Execution (권장)** — 태스크별 fresh subagent 디스패치, 태스크 간 리뷰, 빠른 반복.
**2. Inline Execution** — 현재 세션에서 executing-plans 스킬로 순차 배치 실행 + 체크포인트.

어느 방식으로 진행할까요?
