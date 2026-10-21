#!/usr/bin/env bash
# =============================================================================
#  Lab 3 - Gatekeeper with RHACM                      | 03-lab-finish.sh
#  Removes all lab resources from the hub and the target cluster.
#  Safe to run more than once.
# =============================================================================
set -uo pipefail

LAB_ID="03-gatekeeper"
WORK_DIR="${HOME}/lab-work/${LAB_ID}"
STATE_FILE="${WORK_DIR}/.lab-state"
POLICY_NS="policy-gatekeeper"
OPERATOR_PACKAGE="gatekeeper-operator-product"
LAB_LABEL_VALUE="gatekeeper"

ENV_TARGET="${TARGET_CLUSTER:-}"
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
TARGET_CLUSTER="${ENV_TARGET:-${TARGET_CLUSTER:-cluster1}}"

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

echo "🧹 [LAB FINISH] Cleaning up the Gatekeeper Lab..."
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

# --- 2. Target cluster ---------------------------------------------------------------
KUBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gk-finish.XXXXXX")"
trap 'rm -rf -- "$KUBE_DIR"' EXIT
cd_name="$(hub get clusterdeployments.hive.openshift.io -n "$TARGET_CLUSTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
secret="$(hub get clusterdeployments.hive.openshift.io "$cd_name" -n "$TARGET_CLUSTER" \
    -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' 2>/dev/null)"
if ( umask 077; hub extract "secret/${secret}" -n "$TARGET_CLUSTER" --keys=kubeconfig --to=- >"$KUBE_DIR/target.kubeconfig" 2>/dev/null ) \
   && mc get clusterversion version -o name >/dev/null 2>&1; then

  if mc get namespace app-prod >/dev/null 2>&1; then
    if [[ "$(mc get namespace app-prod -o jsonpath='{.metadata.labels.workshop\.rhacm\.io/lab}')" == "$LAB_LABEL_VALUE" ]]; then
      mc delete namespace app-prod --wait=false >/dev/null 2>&1
    else
      warn "Namespace 'app-prod' was not created by this lab, left untouched"
    fi
  fi

  mc delete containerimagelatest.constraints.gatekeeper.sh containerimagelatest --ignore-not-found >/dev/null 2>&1
  mc delete constrainttemplates.templates.gatekeeper.sh containerimagelatest --ignore-not-found >/dev/null 2>&1

  if mc get crd gatekeepers.operator.gatekeeper.sh >/dev/null 2>&1; then
    mc delete gatekeepers.operator.gatekeeper.sh --all --wait=false >/dev/null 2>&1
    wait_until_gone 180 mc get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration
  fi
  mc delete validatingwebhookconfiguration gatekeeper-validating-webhook-configuration --ignore-not-found >/dev/null 2>&1
  mc delete mutatingwebhookconfiguration gatekeeper-mutating-webhook-configuration --ignore-not-found >/dev/null 2>&1

  for sub in $(mc get subscriptions.operators.coreos.com -n openshift-operators \
      -o jsonpath="{range .items[?(@.spec.name==\"${OPERATOR_PACKAGE}\")]}{.metadata.name}{\"\\n\"}{end}" 2>/dev/null); do
    mc delete subscriptions.operators.coreos.com "$sub" -n openshift-operators >/dev/null 2>&1
  done
  for csv in $(mc get csv -n openshift-operators -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    [[ "$csv" == "${OPERATOR_PACKAGE}."* ]] && mc delete csv "$csv" -n openshift-operators >/dev/null 2>&1
  done
  mc delete namespace openshift-gatekeeper-system --ignore-not-found --wait=false >/dev/null 2>&1
  for crd in $(mc get crd -o name 2>/dev/null | grep -E '\.gatekeeper\.sh$'); do
    mc delete "$crd" --wait=false >/dev/null 2>&1
  done
  info "${TARGET_CLUSTER}: application, constraint and Gatekeeper removed"
else
  warn "Cannot reach '${TARGET_CLUSTER}', its cleanup was skipped. Run this script again later."
fi

# --- 3. Hub: label and namespace -------------------------------------------------
hub label managedcluster "$TARGET_CLUSTER" gatekeeper- >/dev/null 2>&1
if hub get namespace "$POLICY_NS" >/dev/null 2>&1; then
  [[ "$(hub project -q 2>/dev/null)" == "$POLICY_NS" ]] && hub project default >/dev/null 2>&1
  hub delete namespace "$POLICY_NS" --wait=false >/dev/null 2>&1
fi
info "Hub: label removed and namespace '${POLICY_NS}' deleted"

# --- 4. Local lab files -------------------------------------------------------------
[[ -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR" && info "Bastion: lab files removed"

echo ""
echo "✅ Environment is clean for the next lab!"
