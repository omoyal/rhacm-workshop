#!/usr/bin/env bash
set -e

echo "🚀 [LAB START] Preparing environment for Certificate Policy Lab..."

oc get project policies-deploy &>/dev/null || oc new-project policies-deploy >/dev/null 2>&1

TEMP_DIR=$(mktemp -d)
openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
  -keyout "${TEMP_DIR}/tls.key" \
  -out "${TEMP_DIR}/tls.crt" \
  -subj "/CN=router-certs.apps.cluster.local/O=Workshop NonCompliant Ingress" >/dev/null 2>&1

oc create namespace openshift-ingress >/dev/null 2>&1 || true
oc delete secret router-certs -n openshift-ingress >/dev/null 2>&1 || true

oc create secret tls router-certs \
  --cert="${TEMP_DIR}/tls.crt" \
  --key="${TEMP_DIR}/tls.key" \
  -n openshift-ingress >/dev/null 2>&1

rm -rf "${TEMP_DIR}"

echo ""
echo "✅ [LAB READY] Environment successfully primed! The cluster now has a certificate about to expire."
