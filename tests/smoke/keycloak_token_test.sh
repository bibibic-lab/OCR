#!/usr/bin/env bash
set -euo pipefail

# Keycloak OIDC smoke: ocr realm에서 dev-admin 사용자 password grant로 토큰 발급 + introspect.
# dev 한정. 자격은 K8s Secret 'admin/keycloak-dev-creds'에서 조회 (git plaintext 방지).
# Phase 1에 Keycloak 프로덕션 모드 + sealed-secrets/externalSecrets로 강화.

command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not found"; exit 2; }
command -v curl    >/dev/null 2>&1 || { echo "FAIL: curl not found"; exit 2; }
command -v jq      >/dev/null 2>&1 || { echo "FAIL: jq not found"; exit 2; }

# Wait Keycloak Ready
kubectl -n admin wait --for=condition=Ready pod -l app.kubernetes.io/name=keycloak --timeout=5m

# Load credentials from Secret (not from git)
CLIENT_SECRET=$(kubectl -n admin get secret keycloak-dev-creds -o jsonpath='{.data.backoffice-client-secret}' | base64 -d)
DEV_ADMIN_PW=$(kubectl -n admin get secret keycloak-dev-creds -o jsonpath='{.data.dev-admin-password}' | base64 -d)
[ -n "$CLIENT_SECRET" ] && [ -n "$DEV_ADMIN_PW" ] \
  || { echo "FAIL: keycloak-dev-creds Secret missing values"; exit 1; }

# Extract CA to verify TLS
CA=$(mktemp)
trap 'rm -f "$CA"; kill $PF 2>/dev/null || true' EXIT
kubectl -n admin get secret keycloak-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA"

# Port-forward
kubectl -n admin port-forward svc/keycloak 8443:443 >/dev/null 2>&1 &
PF=$!
for _ in $(seq 1 15); do
  nc -z 127.0.0.1 8443 >/dev/null 2>&1 && break
  sleep 1
done

BASE="https://keycloak.admin.svc.cluster.local:8443"
CURL="curl -sk --resolve keycloak.admin.svc.cluster.local:8443:127.0.0.1 --cacert $CA"

# Password grant in ocr realm
TOKEN=$($CURL \
  -d "client_id=ocr-backoffice" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "username=dev-admin" \
  -d "password=$DEV_ADMIN_PW" \
  -d "grant_type=password" \
  "$BASE/realms/ocr/protocol/openid-connect/token" | jq -r .access_token)

[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "FAIL: no access_token for dev-admin in ocr realm"; exit 1; }

# Introspect token (realm ocr)
ACTIVE=$($CURL \
  -u "ocr-backoffice:$CLIENT_SECRET" \
  -d "token=$TOKEN" \
  "$BASE/realms/ocr/protocol/openid-connect/token/introspect" | jq -r .active)

[ "$ACTIVE" = "true" ] || { echo "FAIL: introspect active=$ACTIVE"; exit 1; }

echo "OK: keycloak realm 'ocr' issues tokens (dev-admin, password grant, introspect active)"
