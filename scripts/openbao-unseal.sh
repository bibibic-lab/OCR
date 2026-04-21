#!/usr/bin/env bash
# OpenBao 자동 unseal (dev Shamir 5/3). sealed일 때만 3-key unseal 수행.
# 사용: bash scripts/openbao-unseal.sh
# Phase 1: K8s transit / SoftHSM / 클라우드 KMS로 교체 후 이 스크립트 제거.
set -eu
POD=${OPENBAO_POD:-openbao-0}
NS=${OPENBAO_NS:-security}

bao_exec() {
  kubectl -n "$NS" exec "$POD" -- sh -c "BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true $*"
}

OUT_FILE=$(mktemp)
trap 'rm -f "$OUT_FILE"' EXIT

bao_exec "bao status -format=json" >"$OUT_FILE" 2>/dev/null || true
SEAL_STATUS=$(jq -r 'if has("sealed") then .sealed | tostring else "unknown" end' "$OUT_FILE" 2>/dev/null || echo "unknown")

case "$SEAL_STATUS" in
  false) echo "[openbao-unseal] $POD already unsealed."; exit 0 ;;
  true)  echo "[openbao-unseal] $POD sealed — unsealing..." ;;
  *)     echo "[openbao-unseal] cannot read seal status ($SEAL_STATUS). Pod not ready?"; exit 2 ;;
esac

INIT=$(kubectl -n "$NS" get secret openbao-init-keys -o jsonpath='{.data.init\.json}' | base64 -d)
for K in $(echo "$INIT" | jq -r '.unseal_keys_b64[0,1,2]'); do
  bao_exec "bao operator unseal '$K'" 2>&1 | grep -E 'Sealed|Progress' | head -1 || true
done

bao_exec "bao status -format=json" >"$OUT_FILE" 2>/dev/null || true
FINAL=$(jq -r '.sealed' "$OUT_FILE" 2>/dev/null || echo "error")
if [ "$FINAL" = "false" ]; then
  echo "[openbao-unseal] OK — $POD unsealed."
else
  echo "[openbao-unseal] FAIL — still sealed (got $FINAL). Check logs: kubectl -n $NS logs $POD"
  exit 1
fi
