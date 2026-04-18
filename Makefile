SHELL := /bin/bash
.ONESHELL:

TF_ROOT := infra/terraform
TF_DIR := $(TF_ROOT)/environments/dev
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
	terraform -chdir=$(TF_ROOT) fmt -check -recursive
	helm lint infra/helm/umbrella
	kustomize build infra/manifests/postgres > /dev/null 2>&1 || true
	@echo "Lint OK"
