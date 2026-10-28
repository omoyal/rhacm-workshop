#!/usr/bin/env bash
# =============================================================================
#  Lab 4 - Compliance Operator with RHACM            | 03-lab-finish.sh
#  Removes all lab resources and returns the cluster to its original
#  cluster set. Safe to run more than once.
# =============================================================================
set -uo pipefail

LAB_DIR="${HOME}/DO0013L/labs/policies-compliance"
STATE_FILE="${LAB_DIR}/.lab-state"
POLICY_NS="policies-compliance"
CLUSTER_SET="apac"
OPERATOR_PACKAGE="compliance-operator"
CNS="openshift-compliance"

ENV_TARGET="${TARGET_CLUSTER:-}"
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
TARGET_CLUSTER="${ENV_TARGET:-${TARGET_CLUSTER:-cluster1}}"
PREV_CLUSTERSET="${PREV_CLUSTERSET:-default}"
[[ "$PREV_CLUSTERSET" == "$CLUSTER_SET" ]] && PREV_CLUSTERSET="default"

die()  { echo "❌ [ERROR] $*" >&2; exit 1; }
info() { echo "   • $*"; }
warn() { echo "   ⚠️  $*"; }
hub()  { oc --request-timeout=30s "$@"; }
mc()   { oc --request-timeout=30s --kubeconfig "${KUBE_DIR}/target.kubeconfig" "$@"; }

wait_until_gone() {   # seconds  command...
  local timeout="$1" waited=0
  shift
  while "$@" >/dev/null 2>&1; do
    (( waited >= timeout )) && return 1
    sleep 5
    waited=$((waited + 5))
  done
}
has_any() {   # resource -> succeeds while at least one object exists in the compliance namespace
  [[ -n "$(mc get "$1" -n "$CNS" -o name 2>/dev/null)" ]]
}
clear_finalizers() {   # resource
  local obj
  for obj in $(mc get "$1" -n "$CNS" -o name 2>/dev/null); do
    mc patch "$obj" -n "$CNS" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
  done
}

echo "🧹 [LAB FINISH] Cleaning up the Compliance Operator Lab..."
echo ""

command -v oc >/dev/null 2>&1 || die "The 'oc' CLI was not found."
hub whoami >/dev/null 2>&1 || die "You are not logged in. Log in to your ACM hub with 'oc login' and run again."
hub get crd managedclusters.cluster.open-cluster-management.io >/dev/null 2>&1 \
  || die "Your 'oc' session is not connected to the ACM hub. Log in to the hub and run again."

# --- 1. Hub: lab policies ----------------------------------------------------------
if hub get namespace "$POLICY_NS" >/dev/null 2>&1; then
  hub delete policies.policy.open-cluster-management.io --all -n "$POLICY_NS" --ignore-not-found >/dev/null 2>&1
  hub delete placementbindings.policy.open-cluster-management.io --all -n "$POLICY_NS" --ignore-not-found >/dev/null 2>&1
  hub delete placements.cluster.open-cluster-management.io --all -n "$POLICY_NS" --ignore-not-found >/dev/null 2>&1
  info "Hub: lab policies deleted"
  wait_until_gone 120 bash -c "oc get policies.policy.open-cluster-management.io -n '${TARGET_CLUSTER}' -o name 2>/dev/null | grep '/${POLICY_NS}\.' >/dev/null" \
    || warn "Policies are still being removed from '${TARGET_CLUSTER}', continuing"
fi

# --- 2. Target cluster: scan, operator, namespace, CRDs -----------------------------
KUBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compliance-finish.XXXXXX")"
trap 'rm -rf -- "$KUBE_DIR"' EXIT
cd_name="$(hub get clusterdeployments.hive.openshift.io -n "$TARGET_CLUSTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
secret="$(hub get clusterdeployments.hive.openshift.io "$cd_name" -n "$TARGET_CLUSTER" \
    -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' 2>/dev/null)"
if ( umask 077; hub extract "secret/${secret}" -n "$TARGET_CLUSTER" --keys=kubeconfig --to=- >"$KUBE_DIR/target.kubeconfig" 2>/dev/null ) \
   && mc get clusterversion version -o name >/dev/null 2>&1; then

  if mc get crd compliancesuites.compliance.openshift.io >/dev/null 2>&1; then
    # Scans first, while the operator is still running to process their finalizers
    for r in scansettingbindings.compliance.openshift.io compliancesuites.compliance.openshift.io compliancescans.compliance.openshift.io; do
      mc delete "$r" --all -n "$CNS" --wait=false >/dev/null 2>&1
    done
    for r in scansettingbindings.compliance.openshift.io compliancesuites.compliance.openshift.io compliancescans.compliance.openshift.io; do
      wait_until_gone 180 has_any "$r" || clear_finalizers "$r"
    done
    mc delete profilebundles.compliance.openshift.io --all -n "$CNS" --wait=false >/dev/null 2>&1
    wait_until_gone 120 has_any profilebundles.compliance.openshift.io || clear_finalizers profilebundles.compliance.openshift.io
  fi

  for sub in $(mc get subscriptions.operators.coreos.com -n "$CNS" \
      -o jsonpath="{range .items[?(@.spec.name==\"${OPERATOR_PACKAGE}\")]}{.metadata.name}{\"\\n\"}{end}" 2>/dev/null); do
    mc delete subscriptions.operators.coreos.com "$sub" -n "$CNS" >/dev/null 2>&1
  done
  for csv in $(mc get csv -n "$CNS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    [[ "$csv" == "${OPERATOR_PACKAGE}."* ]] && mc delete csv "$csv" -n "$CNS" >/dev/null 2>&1
  done
  mc delete operatorgroups.operators.coreos.com --all -n "$CNS" --ignore-not-found >/dev/null 2>&1
  mc delete namespace "$CNS" --ignore-not-found --wait=false >/dev/null 2>&1
  for crd in $(mc get crd -o name 2>/dev/null | grep -E '\.compliance\.openshift\.io$'); do
    mc delete "$crd" --wait=false >/dev/null 2>&1
  done
  info "${TARGET_CLUSTER}: E8 scan and Compliance Operator removed"
else
  warn "Cannot reach '${TARGET_CLUSTER}', its cleanup was skipped. Run this script again later."
fi

# --- 3. Hub: cluster set, namespace --------------------------------------------------
if hub get managedcluster "$TARGET_CLUSTER" >/dev/null 2>&1; then
  current="$(hub get managedcluster "$TARGET_CLUSTER" -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}' 2>/dev/null)"
  if [[ "$current" == "$CLUSTER_SET" || -z "$current" ]]; then
    hub label managedcluster "$TARGET_CLUSTER" "cluster.open-cluster-management.io/clusterset=${PREV_CLUSTERSET}" --overwrite >/dev/null 2>&1 \
      && info "Hub: '${TARGET_CLUSTER}' returned to cluster set '${PREV_CLUSTERSET}'" \
      || warn "Could not return '${TARGET_CLUSTER}' to cluster set '${PREV_CLUSTERSET}'. Do it from Infrastructure > Clusters > Cluster sets."
  fi
fi
if hub get managedclusterset "$CLUSTER_SET" >/dev/null 2>&1; then
  members="$(hub get managedclusters -l "cluster.open-cluster-management.io/clusterset=${CLUSTER_SET}" -o name 2>/dev/null)"
  if [[ -z "$members" ]]; then
    hub delete managedclusterset "$CLUSTER_SET" >/dev/null 2>&1 && info "Hub: cluster set '${CLUSTER_SET}' deleted"
  else
    warn "Cluster set '${CLUSTER_SET}' still has clusters (${members//$'\n'/ }), left in place"
  fi
fi
if hub get namespace "$POLICY_NS" >/dev/null 2>&1; then
  [[ "$(hub project -q 2>/dev/null)" == "$POLICY_NS" ]] && hub project default >/dev/null 2>&1
  hub delete namespace "$POLICY_NS" --wait=false >/dev/null 2>&1
  info "Hub: project '${POLICY_NS}' deleted"
fi

# --- 4. Local lab files -------------------------------------------------------------
if [[ -d "$LAB_DIR" ]]; then
  rm -rf -- "$LAB_DIR"
  rmdir "${HOME}/DO0013L/labs" "${HOME}/DO0013L" 2>/dev/null
  info "Bastion: lab files removed"
fi

echo ""
echo "✅ Environment is clean for the next lab!"
