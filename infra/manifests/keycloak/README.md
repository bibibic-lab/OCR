# Keycloak realm import

`realm-ocr.json` contains two placeholders that must be substituted before import:

- `__BACKOFFICE_CLIENT_SECRET__` — OIDC client secret for `ocr-backoffice`
- `__DEV_ADMIN_PASSWORD__` — initial password for `dev-admin` user

Both are stored in K8s Secret `admin/keycloak-dev-creds` in dev. Phase 1 will migrate to
sealed-secrets/external-secrets.

## Import flow

```bash
# 1. fetch credentials from Secret
CLIENT_SECRET=$(kubectl -n admin get secret keycloak-dev-creds -o jsonpath='{.data.backoffice-client-secret}' | base64 -d)
DEV_ADMIN_PW=$(kubectl -n admin get secret keycloak-dev-creds -o jsonpath='{.data.dev-admin-password}' | base64 -d)

# 2. substitute placeholders to a tmp file
sed -e "s|__BACKOFFICE_CLIENT_SECRET__|$CLIENT_SECRET|" \
    -e "s|__DEV_ADMIN_PASSWORD__|$DEV_ADMIN_PW|" \
    realm-ocr.json > /tmp/realm-resolved.json

# 3. import via REST (port-forward + curl) or kcadm.sh; resolved file is not committed
```

The resolved file should never be committed. `.gitignore` covers `/tmp/realm-resolved.json` by convention.
