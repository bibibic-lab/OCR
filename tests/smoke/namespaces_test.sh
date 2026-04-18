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
