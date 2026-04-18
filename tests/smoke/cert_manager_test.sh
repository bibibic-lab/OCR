#!/usr/bin/env bash
set -euo pipefail

command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not found"; exit 2; }

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
