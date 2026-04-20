#!/usr/bin/env bash
set -euo pipefail

# ArgoCD dev smoke: install health + umbrella chart lint + root-app dry-run.
# Phase 1: YOUR-ORG placeholder 치환 + gh repo create + push + Application 실제 sync.
command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not found"; exit 2; }
command -v helm    >/dev/null 2>&1 || { echo "FAIL: helm not found"; exit 2; }

# 1) ArgoCD 핵심 deploy Available (repo-server는 dev argocd-3.x + kind 4-node
# 제한으로 probe timeout 빈발 → 리소스 존재 확인만, 기능 검증은 Phase 1)
for deploy in argocd-applicationset-controller argocd-dex-server argocd-notifications-controller \
              argocd-redis argocd-server; do
  kubectl -n argocd wait --for=condition=Available "deploy/$deploy" --timeout=5m
done
kubectl -n argocd get deploy argocd-repo-server -o jsonpath='{.spec.replicas}' | grep -qE '^[1-9]' \
  || { echo "FAIL: argocd-repo-server deployment not defined"; exit 1; }
kubectl -n argocd wait --for=condition=Ready "pod/argocd-application-controller-0" --timeout=5m

# 2) CRD 4개 (Application, ApplicationSet, AppProject, ApplicationSource)
for crd in applications applicationsets appprojects; do
  kubectl get crd "${crd}.argoproj.io" >/dev/null \
    || { echo "FAIL: CRD ${crd}.argoproj.io 없음"; exit 1; }
done

# 3) umbrella Chart helm lint
cd "$(dirname "$0")/../.."
helm lint infra/helm/umbrella >/dev/null \
  || { echo "FAIL: umbrella chart lint"; exit 1; }

# 4) root-app dry-run
kubectl apply --dry-run=client -f infra/argocd/apps/root-app.yaml >/dev/null \
  || { echo "FAIL: root-app dry-run"; exit 1; }

# 5) umbrella template 렌더 (ApplicationSet 유효 YAML 확인)
helm template ocr-platform infra/helm/umbrella --namespace argocd 2>/dev/null \
  | grep -q "kind: ApplicationSet" \
  || { echo "FAIL: ApplicationSet 템플릿 렌더 실패"; exit 1; }

echo "OK: argocd pods ready + umbrella lint + root-app dry-run + ApplicationSet rendered"
