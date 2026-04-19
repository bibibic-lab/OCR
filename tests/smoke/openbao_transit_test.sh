#!/usr/bin/env bash
set -euo pipefail

# OpenBao Transit KEK encrypt/decrypt roundtrip.
# Dev: 1-node Raft(Shamir). Phase 1 TODO: 3-node HA 복원 (Cilium raft challenge 이슈).
command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not found"; exit 2; }
command -v jq       >/dev/null 2>&1 || { echo "FAIL: jq not found"; exit 2; }

ROOT=$(kubectl -n security get secret openbao-init-keys -o jsonpath='{.data.init\.json}' \
  | base64 -d | jq -r .root_token)
[ -n "$ROOT" ] && [ "$ROOT" != "null" ] || { echo "FAIL: cannot read root token"; exit 1; }

PLAINTEXT=$(echo -n "hello-ocr-encryption-$(date +%s)" | base64)

CT=$(kubectl -n security exec openbao-0 -- sh -c "
  BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN='$ROOT' \
  bao write -format=json transit/encrypt/upload-kek plaintext='$PLAINTEXT'
" 2>/dev/null | jq -r .data.ciphertext)

[ -n "$CT" ] && [ "$CT" != "null" ] || { echo "FAIL: encryption returned no ciphertext"; exit 1; }

DEC=$(kubectl -n security exec openbao-0 -- sh -c "
  BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_TOKEN='$ROOT' \
  bao write -format=json transit/decrypt/upload-kek ciphertext='$CT'
" 2>/dev/null | jq -r .data.plaintext | base64 -d)

expected=$(echo -n "$PLAINTEXT" | base64 -d)
[ "$DEC" = "$expected" ] || { echo "FAIL: decrypt mismatch — expected '$expected' got '$DEC'"; exit 1; }

echo "OK: openbao transit upload-kek encrypt/decrypt roundtrip"
