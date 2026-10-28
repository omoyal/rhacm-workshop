#!/usr/bin/env bash
# =============================================================================
#  Lab 5 - Enable the RHACM Observability Stack        | 03-lab-finish.sh
#  Disables observability and removes the lab resources from the hub.
#  OpenShift Data Foundation (Multicloud Object Gateway) stays installed so the
#  next observability lab can reuse it. Safe to run more than once.
# =============================================================================
set -uo pipefail

LAB_DIR="${HOME}/DO0014L/labs/observability-enable"
STATE_FILE="${LAB_DIR}/.lab-state"
OBS_NS="open-cluster-management-observability"

ENV_TARGET="${TARGET_CLUSTER:-}"
DISABLED_BY_LAB=""
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
TARGET_CLUSTER="${ENV_TARGET:-${TARGET_CLUSTER:-cluster1}}"

die()  { echo "❌ [ERROR] $*" >&2; exit 1; }
info() { echo "   • $*"; }
warn() { echo "   ⚠️  $*"; }
hub()  { oc --request-timeout=30s "$@"; }

wait_until_gone() {   # seconds  command...
  local timeout="$1" waited=0
  shift
  while "$@" >/dev/null 2>&1; do
    (( waited >= timeout )) && return 1
    sleep 5
    waited=$((waited + 5))
  done
}

echo "🧹 [LAB FINISH] Cleaning up the Observability Lab..."
echo ""

command -v oc >/dev/null 2>&1 || die "The 'oc' CLI was not found."
if ! login_err="$(hub whoami 2>&1)"; then
  echo "❌ [ERROR] 'oc' is not logged in to a cluster:" >&2
  echo "      ${login_err}" >&2
  [[ -n "${KUBECONFIG:-}" ]] && echo "   KUBECONFIG is set to '${KUBECONFIG}'. If this is not your hub, run: unset KUBECONFIG" >&2
  echo "   Log in to your ACM hub: hub console > user menu (top right) > Copy login command > Display Token," >&2
  echo "   then run the 'oc login --token=...' command on the Bastion, and run this script again." >&2
  exit 1
fi
hub get crd managedclusters.cluster.open-cluster-management.io >/dev/null 2>&1 \
  || die "Your 'oc' session is not connected to the ACM hub. Log in to the hub and run again."

# --- 1. Disable observability (the operator removes the add-on from all clusters)
if hub get multiclusterobservability observability >/dev/null 2>&1; then
  hub delete multiclusterobservability observability --wait=false >/dev/null 2>&1
  if wait_until_gone 300 hub get multiclusterobservability observability; then
    info "Hub: MultiClusterObservability deleted"
  else
    warn "MultiClusterObservability is still being deleted after 5 minutes, removing its finalizers"
    hub patch multiclusterobservability observability --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
  fi
fi

# --- 2. Object bucket claim, secrets and namespace ----------------------------------
if hub get namespace "$OBS_NS" >/dev/null 2>&1; then
  if hub get objectbucketclaim thanos-obc -n "$OBS_NS" >/dev/null 2>&1; then
    hub delete objectbucketclaim thanos-obc -n "$OBS_NS" --wait=false >/dev/null 2>&1
    wait_until_gone 120 hub get objectbucketclaim thanos-obc -n "$OBS_NS" \
      || hub patch objectbucketclaim thanos-obc -n "$OBS_NS" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
    info "Hub: object bucket claim 'thanos-obc' deleted"
  fi
  [[ "$(hub project -q 2>/dev/null)" == "$OBS_NS" ]] && hub project default >/dev/null 2>&1
  hub delete namespace "$OBS_NS" --wait=false >/dev/null 2>&1
  info "Hub: namespace '${OBS_NS}' deleted"
fi

# --- 3. Cluster labels ---------------------------------------------------------------
if [[ "$(hub get managedcluster "$TARGET_CLUSTER" -o jsonpath='{.metadata.labels.observability}' 2>/dev/null)" == "disabled" ]]; then
  hub label managedcluster "$TARGET_CLUSTER" observability- >/dev/null 2>&1
fi
for c in $DISABLED_BY_LAB; do
  hub label managedcluster "$c" observability- >/dev/null 2>&1
done
info "Hub: observability labels removed from the managed clusters"

# --- 4. Local lab files -------------------------------------------------------------
if [[ -d "$LAB_DIR" ]]; then
  rm -rf -- "$LAB_DIR"
  rmdir "${HOME}/DO0014L/labs" "${HOME}/DO0014L" 2>/dev/null
  info "Bastion: lab files removed"
fi

echo ""
echo "ℹ️  OpenShift Data Foundation (Multicloud Object Gateway) remains installed on the hub for the next labs."
echo "✅ Environment is clean for the next lab!"
