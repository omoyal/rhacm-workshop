#!/usr/bin/env bash
# =============================================================================
#  Lab 3 - Integrate Gatekeeper with RHACM            | 03-lab-finish.sh
# -----------------------------------------------------------------------------
#  Removes every trace of the lab (equivalent of "lab finish"):
#   Hub     : lab policies, placements, bindings, the policy-gatekeeper namespace
#   Clusters: app namespaces, constraints, Gatekeeper instance + operator + CRDs
#   Labels  : environment labels restored to their values before the lab
#   Bastion : ~/lab-work/03-gatekeeper
#  Safe to run more than once.
# =============================================================================
set -uo pipefail

LAB_ID="03-gatekeeper"
WORK_DIR="${HOME}/lab-work/${LAB_ID}"
STATE_FILE="${WORK_DIR}/.lab-state"
POLICY_NS="policy-gatekeeper"
LAB_LABEL_KEY="workshop.rhacm.io/lab"
LAB_LABEL_VALUE="gatekeeper"
OPERATOR_PACKAGE="gatekeeper-operator-product"

# ---------------------------------------------------------------- helpers ---
die()  { echo "❌ [ERROR] $*" >&2; exit 1; }
info() { echo "   • $*"; }
warn() { echo "   ⚠️  $*"; }
hub()  { oc --request-timeout=30s "$@"; }
ocx()  { local role="$1"; shift; oc --request-timeout=30s --kubeconfig "${KUBE_DIR}/${role}.kubeconfig" "$@"; }

require_hub() {
  command -v oc >/dev/null 2>&1 || die "The 'oc' CLI was not found on this machine."
  hub whoami >/dev/null 2>&1 || die "You are not logged in. Log in to your ACM hub with 'oc login' and run again."
  hub get crd managedclusters.cluster.open-cluster-management.io >/dev/null 2>&1 \
    || die "Your current 'oc' session is not the ACM hub. Run 'unset KUBECONFIG' (or log in to the hub) and run again."
}

load_state() {
  local env_stage="${STAGE_CLUSTER:-}" env_prod="${PROD_CLUSTER:-}"
  STATE_LOADED=0
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    STATE_LOADED=1
  fi
  [[ -n "$env_stage" ]] && STAGE_CLUSTER="$env_stage"
  [[ -n "$env_prod" ]] && PROD_CLUSTER="$env_prod"
  return 0
}

discover_clusters() {
  [[ -n "${STAGE_CLUSTER:-}" && -n "${PROD_CLUSTER:-}" ]] && return 0
  local managed=()
  mapfile -t managed < <(hub get managedclusters -l 'local-cluster!=true' \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -vx 'local-cluster' | grep -v '^$' | sort)
  if [[ ${#managed[@]} -ne 2 ]]; then
    echo "❌ Expected exactly 2 managed clusters (besides local-cluster), found ${#managed[@]}: ${managed[*]:-none}" >&2
    echo "   Run again with:  STAGE_CLUSTER=<name> PROD_CLUSTER=<name> $0" >&2
    return 1
  fi
  STAGE_CLUSTER="${managed[0]}"
  PROD_CLUSTER="${managed[1]}"
}

fetch_kubeconfig() {   # $1 = managed cluster name, $2 = destination file
  local cluster="$1" dest="$2" cd secret
  cd="$(hub get clusterdeployments.hive.openshift.io -n "$cluster" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "$cd" ]] || { echo "❌ No ClusterDeployment found for '$cluster' (this lab expects clusters created by ACM)." >&2; return 1; }
  secret="$(hub get clusterdeployments.hive.openshift.io "$cd" -n "$cluster" \
      -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' 2>/dev/null)"
  [[ -n "$secret" ]] || { echo "❌ '$cluster' has no admin kubeconfig yet. Is it fully provisioned?" >&2; return 1; }
  ( umask 077; hub extract "secret/${secret}" -n "$cluster" --keys=kubeconfig --to=- >"$dest" 2>/dev/null ) \
    || { echo "❌ Cannot read the admin kubeconfig of '$cluster'." >&2; return 1; }
  oc --request-timeout=30s --kubeconfig "$dest" get clusterversion version -o name >/dev/null 2>&1 \
    || { echo "❌ The API of '$cluster' is not reachable from this bastion." >&2; return 1; }
}

wait_until_gone() {   # $1 seconds  $2.. command that succeeds while the object still exists
  local timeout="$1" waited=0
  shift
  while "$@" >/dev/null 2>&1; do
    (( waited >= timeout )) && return 1
    sleep 5
    waited=$((waited + 5))
  done
  return 0
}

# Root policies on the hub (any namespace) that install the Gatekeeper operator
gatekeeper_policies() {
  local p
  for p in $(hub get policies.policy.open-cluster-management.io -A -l '!policy.open-cluster-management.io/root-policy' \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    hub get policies.policy.open-cluster-management.io "${p#*/}" -n "${p%%/*}" -o yaml 2>/dev/null \
      | grep "$OPERATOR_PACKAGE" >/dev/null && echo "$p"
  done
}

restore_label() {   # $1 cluster  $2 previous value ("" = had no label)
  hub get managedcluster "$1" >/dev/null 2>&1 || return 0
  if [[ -n "$2" ]]; then
    hub label managedcluster "$1" "environment=$2" --overwrite >/dev/null
  else
    hub label managedcluster "$1" environment- >/dev/null 2>&1
  fi
}

cleanup_cluster() {   # $1 role (stage|production)  $2 cluster name
  local role="$1" name="$2" ns owner sub csv crd

  # Lab application namespaces (only if this lab created them)
  for ns in app-stage app-test app-prod; do
    ocx "$role" get namespace "$ns" >/dev/null 2>&1 || continue
    owner="$(ocx "$role" get namespace "$ns" -o jsonpath="{.metadata.labels.workshop\.rhacm\.io/lab}" 2>/dev/null)"
    if [[ "$owner" == "$LAB_LABEL_VALUE" ]]; then
      ocx "$role" delete namespace "$ns" --wait=false >/dev/null 2>&1
    else
      warn "${name}: namespace '$ns' was not created by this lab (no ${LAB_LABEL_KEY}=${LAB_LABEL_VALUE} label), left untouched"
    fi
  done

  # Lab constraint (normally removed by RHACM together with the policy)
  ocx "$role" delete containerimagelatest.constraints.gatekeeper.sh containerimagelatest --ignore-not-found >/dev/null 2>&1
  ocx "$role" delete constrainttemplates.templates.gatekeeper.sh containerimagelatest --ignore-not-found >/dev/null 2>&1

  # Gatekeeper instance -> the operator removes its webhooks and pods
  if ocx "$role" get crd gatekeepers.operator.gatekeeper.sh >/dev/null 2>&1; then
    ocx "$role" delete gatekeepers.operator.gatekeeper.sh --all --wait=false >/dev/null 2>&1
    wait_until_gone 180 ocx "$role" get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration \
      || warn "${name}: Gatekeeper webhook still present after 3 minutes, removing it directly"
  fi
  ocx "$role" delete validatingwebhookconfiguration gatekeeper-validating-webhook-configuration --ignore-not-found >/dev/null 2>&1
  ocx "$role" delete mutatingwebhookconfiguration gatekeeper-mutating-webhook-configuration --ignore-not-found >/dev/null 2>&1

  # Operator: Subscription + CSV
  for sub in $(ocx "$role" get subscriptions.operators.coreos.com -n openshift-operators \
      -o jsonpath="{range .items[?(@.spec.name==\"${OPERATOR_PACKAGE}\")]}{.metadata.name}{\"\\n\"}{end}" 2>/dev/null); do
    ocx "$role" delete subscriptions.operators.coreos.com "$sub" -n openshift-operators >/dev/null 2>&1
  done
  for csv in $(ocx "$role" get csv -n openshift-operators -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    [[ "$csv" == "${OPERATOR_PACKAGE}."* ]] && ocx "$role" delete csv "$csv" -n openshift-operators >/dev/null 2>&1
  done

  # Gatekeeper namespace and CRDs
  ocx "$role" delete namespace openshift-gatekeeper-system --ignore-not-found --wait=false >/dev/null 2>&1
  for crd in $(ocx "$role" get crd -o name 2>/dev/null | grep -E '\.gatekeeper\.sh$'); do
    ocx "$role" delete "$crd" --wait=false >/dev/null 2>&1
  done

  info "${name}: app namespaces, constraint and Gatekeeper removed"
}

# ------------------------------------------------------------------- main ---
echo "🧹 [LAB FINISH] Cleaning up the Gatekeeper Lab..."
echo ""

require_hub
load_state
CLUSTERS_OK=1
discover_clusters || CLUSTERS_OK=0

# --- 1. Hub: policies first, so RHACM stops re-creating objects --------------
if hub get namespace "$POLICY_NS" >/dev/null 2>&1; then
  hub delete policies.policy.open-cluster-management.io --all -n "$POLICY_NS" --ignore-not-found >/dev/null 2>&1
  hub delete placementbindings.policy.open-cluster-management.io --all -n "$POLICY_NS" --ignore-not-found >/dev/null 2>&1
  hub delete placements.cluster.open-cluster-management.io --all -n "$POLICY_NS" --ignore-not-found >/dev/null 2>&1
  info "Hub: lab policies, placements and bindings deleted"
fi
other_policies="$(gatekeeper_policies)"
if [[ -n "$other_policies" ]]; then
  warn "These RHACM policies (not part of this lab) also install Gatekeeper and will re-install it:"
  sed 's/^/        - /' <<<"$other_policies"
  warn "Delete them first if you want Gatekeeper fully removed, then run this script again."
fi

# --- 2. Managed clusters -------------------------------------------------------
if [[ "$CLUSTERS_OK" -eq 1 ]]; then
  KUBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gk-finish.XXXXXX")"
  trap 'rm -rf -- "$KUBE_DIR"' EXIT

  # Wait until RHACM has withdrawn the replicated policies from both clusters
  for c in "$STAGE_CLUSTER" "$PROD_CLUSTER"; do
    wait_until_gone 120 bash -c "oc --request-timeout=30s get policies.policy.open-cluster-management.io -n '$c' -o name 2>/dev/null | grep '/${POLICY_NS}\.' >/dev/null" \
      || warn "${c}: replicated lab policies still present after 2 minutes, continuing anyway"
  done

  for pair in "stage:${STAGE_CLUSTER}" "production:${PROD_CLUSTER}"; do
    role="${pair%%:*}"; name="${pair#*:}"
    if fetch_kubeconfig "$name" "$KUBE_DIR/${role}.kubeconfig"; then
      cleanup_cluster "$role" "$name"
    else
      warn "${name}: cannot reach the cluster, its cleanup was skipped. Run this script again later."
    fi
  done

  # --- 3. Restore the environment labels -------------------------------------
  if [[ "$STATE_LOADED" -eq 1 ]]; then
    restore_label "$STAGE_CLUSTER" "${PREV_ENV_STAGE:-}"
    restore_label "$PROD_CLUSTER" "${PREV_ENV_PROD:-}"
    [[ -n "${PREV_ENV_HUB:-}" ]] && restore_label local-cluster "$PREV_ENV_HUB"
  else
    # No saved state: remove only the labels this lab sets
    [[ "$(hub get managedcluster "$STAGE_CLUSTER" -o jsonpath='{.metadata.labels.environment}' 2>/dev/null)" == "stage" ]] \
      && restore_label "$STAGE_CLUSTER" ""
    [[ "$(hub get managedcluster "$PROD_CLUSTER" -o jsonpath='{.metadata.labels.environment}' 2>/dev/null)" == "production" ]] \
      && restore_label "$PROD_CLUSTER" ""
  fi
  info "Hub: environment labels restored"
else
  warn "Managed clusters could not be identified - only the hub was cleaned."
fi

# --- 4. Hub namespace (also removes the ManagedClusterSetBinding) -------------
if hub get namespace "$POLICY_NS" >/dev/null 2>&1; then
  [[ "$(hub project -q 2>/dev/null)" == "$POLICY_NS" ]] && hub project default >/dev/null 2>&1
  hub delete namespace "$POLICY_NS" --wait=false >/dev/null 2>&1
  info "Hub: namespace '${POLICY_NS}' deleted"
fi

# --- 5. Local lab files ------------------------------------------------------------
if [[ -d "$WORK_DIR" && "$WORK_DIR" == "${HOME}/lab-work/${LAB_ID}" ]]; then
  rm -rf -- "$WORK_DIR"
  info "Bastion: ${WORK_DIR} removed"
fi

echo ""
echo "✅ Environment is clean for the next lab!"
