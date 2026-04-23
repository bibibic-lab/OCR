#!/bin/sh
set -eu

BAO_ADDR="${BAO_ADDR:-https://openbao.security.svc.cluster.local:8200}"
KEYS_FILE="${KEYS_FILE:-/etc/openbao/init.json}"
INTERVAL="${INTERVAL:-10}"
CA_FILE="${CA_FILE:-/etc/ssl/openbao-ca/ca.crt}"

log() { printf '%s %s\n' "$(date -Iseconds)" "$*"; }

if [ ! -f "$KEYS_FILE" ]; then
  log "FATAL: $KEYS_FILE not found"
  exit 1
fi

if [ ! -f "$CA_FILE" ]; then
  log "FATAL: CA file $CA_FILE not found"
  exit 1
fi

log "openbao-unsealer starting — watching $BAO_ADDR"
COUNT=0

while :; do
  # Fetch seal-status; BAO may return HTTP 503 when sealed, 200 when unsealed.
  STATUS_HTTP=$(curl --cacert "$CA_FILE" -s -o /tmp/status.json -w "%{http_code}" \
                 "$BAO_ADDR/v1/sys/seal-status" 2>/dev/null || echo "000")

  if [ "$STATUS_HTTP" = "000" ]; then
    log "WARN: unreachable (pod may be starting), retry in ${INTERVAL}s"
    sleep "$INTERVAL"
    continue
  fi

  # NOTE: use `| tostring` not `// "unknown"` because jq treats JSON false as
  # falsy and `false // "unknown"` returns "unknown". tostring correctly gives "false".
  SEALED=$(jq -r 'if has("sealed") then .sealed | tostring else "unknown" end' /tmp/status.json)

  if [ "$SEALED" = "true" ]; then
    log "sealed=true (http=${STATUS_HTTP}), attempting unseal"
    # Use first 3 keys (threshold=3) from unseal_keys_b64
    KEYS=$(jq -r '.unseal_keys_b64[0:3][]' "$KEYS_FILE")
    STEP=0
    NEW_SEALED="unknown"
    for K in $KEYS; do
      STEP=$((STEP + 1))
      RESP=$(curl --cacert "$CA_FILE" -s -X POST \
             --data "{\"key\":\"$K\"}" \
             "$BAO_ADDR/v1/sys/unseal" 2>/dev/null || echo '{"sealed":true}')
      NEW_SEALED=$(echo "$RESP" | jq -r 'if has("sealed") then .sealed | tostring else "unknown" end')
      log "  unseal step $STEP/3: sealed=$NEW_SEALED"
      if [ "$NEW_SEALED" = "false" ]; then
        log "unseal SUCCESS after $STEP key(s)"
        break
      fi
    done
    if [ "$NEW_SEALED" != "false" ]; then
      log "WARN: unseal attempt complete but sealed=$NEW_SEALED — will retry"
    fi
    COUNT=0
  elif [ "$SEALED" = "false" ]; then
    COUNT=$((COUNT + 1))
    # Heartbeat every 60 iterations (~10min at 10s interval) to reduce noise
    if [ $((COUNT % 60)) -eq 0 ]; then
      log "heartbeat: unsealed (count=$COUNT)"
    fi
  else
    log "WARN: unexpected sealed value='$SEALED' (http=$STATUS_HTTP)"
  fi

  sleep "$INTERVAL"
done
