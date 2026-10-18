#!/usr/bin/env bash
set -e

echo "🧹 [LAB FINISH] Cleaning up lab resources..."

oc delete secret router-certs -n openshift-ingress >/dev/null 2>&1 || true
oc delete project policies-deploy >/dev/null 2>&1 || true

echo "✅ Environment is clean for the next lab!"
