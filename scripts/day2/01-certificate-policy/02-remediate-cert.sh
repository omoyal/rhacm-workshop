#!/usr/bin/env bash
set -e

echo "🔧 [REMEDIATE] Generating a compliant certificate (valid for 365 days)..."

TEMP_DIR=$(mktemp -d)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${TEMP_DIR}/tls.key" \
  -out "${TEMP_DIR}/tls.crt" \
  -subj "/CN=router-certs.apps.cluster.local/O=Workshop Compliant Ingress" >/dev/null 2>&1

oc delete secret router-certs -n openshift-ingress >/dev/null 2>&1 || true

oc create secret tls router-certs \
  --cert="${TEMP_DIR}/tls.crt" \
  --key="${TEMP_DIR}/tls.key" \
  -n openshift-ingress >/dev/null 2>&1

rm -rf "${TEMP_DIR}"

echo "✅ [SUCCESS] Certificate updated successfully with 365-day validity!"
echo "👉 Check the RHACM Console (Results tab). It should become green shortly."
