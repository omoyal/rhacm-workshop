#!/usr/bin/env bash
# =============================================================================
#  Lab 3 - Integrate Gatekeeper with RHACM            | 02-check.sh
# -----------------------------------------------------------------------------
#  Grades the lab (score out of 100). Read-only: changes nothing on any
#  cluster. The enforcement test is a server-side dry run, so nothing is saved.
# =============================================================================
set -uo pipefail

LAB_ID="03-gatekeeper"
WORK_DIR="${HOME}/lab-work/${LAB_ID}"
STATE_FILE="${WORK_DIR}/.lab-state"
POLICY_NS="policy-gatekeeper"
APP_IMAGE="${APP_IMAGE:-quay.io/redhattraining/hello-world-nginx}"
PASS_SCORE=80

# ---------------------------------------------------------------- helpers ---
die()  { echo "❌ [ERROR] $*" >&2; exit 1; }
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
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
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

# Placement name bound to a policy (via its PlacementBinding)
placement_of() {
  hub get placementbindings.policy.open-cluster-management.io -n "$POLICY_NS" \
      -o jsonpath='{range .items[*]}{.placementRef.name}{" "}{.subjects[*].name}{"\n"}{end}' 2>/dev/null \
    | awk -v p="$1" '{for (i = 2; i <= NF; i++) if ($i == p) {print $1; exit}}'
}

# Sorted, space-separated list of clusters a Placement selected
decisions_of() {
  hub get placementdecisions.cluster.open-cluster-management.io -n "$POLICY_NS" \
      -l "cluster.open-cluster-management.io/placement=$1" \
      -o jsonpath='{.items[*].status.decisions[*].clusterName}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sort -u | xargs
}

ready_replicas() {   # $1 role  $2 namespace  $3 deployment
  local n
  n="$(ocx "$1" get deployment "$3" -n "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  echo "${n:-0}"
}

# ---------------------------------------------------------------- scoring ---
SCORE=0
TOTAL=0
check() {   # $1 weight  $2 description  $3 hint  $4.. command
  local weight="$1" desc="$2" hint="$3"
  shift 3
  TOTAL=$((TOTAL + weight))
  if "$@" >/dev/null 2>&1; then
    SCORE=$((SCORE + weight))
    printf '  ✅ %3d/%-3d %s\n' "$weight" "$weight" "$desc"
  else
    printf '  ❌ %3d/%-3d %s\n' 0 "$weight" "$desc"
    printf '              👉 %s\n' "$hint"
  fi
}

# ------------------------------------------------------------------ tests ---
t_namespace() { hub get namespace "$POLICY_NS"; }

t_binding() {
  [[ "$(hub get managedclustersetbindings.cluster.open-cluster-management.io default -n "$POLICY_NS" \
        -o jsonpath='{.spec.clusterSet}' 2>/dev/null)" == "default" ]]
}

t_operator_policy() {
  local yaml
  yaml="$(hub get policies.policy.open-cluster-management.io policy-gatekeeper-operator -n "$POLICY_NS" -o yaml 2>/dev/null)" || return 1
  grep -Eq '^  remediationAction: enforce' <<<"$yaml" && grep -q 'kind: OperatorPolicy' <<<"$yaml"
}

t_operator_placement() {
  local p
  p="$(placement_of policy-gatekeeper-operator)"
  [[ -n "$p" && "$(decisions_of "$p")" == "$EXPECTED_CLUSTERS" ]]
}

t_operator_ready() {   # $1 role
  ocx "$1" get csv -n openshift-operators \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -E '^gatekeeper-operator-product\.[^ ]+ Succeeded$' >/dev/null || return 1
  [[ "$(ready_replicas "$1" openshift-gatekeeper-system gatekeeper-controller-manager)" -ge 1 ]]
}

t_exclusion() {
  hub get policies.policy.open-cluster-management.io policy-gatekeeper-operator -n "$POLICY_NS" -o yaml 2>/dev/null \
    | grep -A4 'excludedNamespaces:' | grep 'app-stage' >/dev/null || return 1
  ocx stage get configs.config.gatekeeper.sh config -n openshift-gatekeeper-system \
      -o jsonpath='{.spec.match[*].excludedNamespaces[*]}' 2>/dev/null | tr ' ' '\n' | grep -x 'app-stage' >/dev/null
}

t_latest_placement() {
  local p
  p="$(placement_of policy-gatekeeper-containerimage-latest)"
  [[ -n "$p" && "$(decisions_of "$p")" == "$EXPECTED_CLUSTERS" ]]
}

t_constraint() {   # $1 role
  ocx "$1" get constrainttemplates.templates.gatekeeper.sh containerimagelatest && \
  ocx "$1" get containerimagelatest.constraints.gatekeeper.sh containerimagelatest
}

t_stage_hello() {
  local img
  img="$(ocx stage get deployment stage-hello -n app-stage -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  [[ "$img" == *:latest && "$(ready_replicas stage app-stage stage-hello)" -ge 1 ]]
}

t_prod_hello() {
  local img
  img="$(ocx production get deployment prod-hello -n app-prod -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  [[ -n "$img" && "$img" != *:latest && "$(ready_replicas production app-prod prod-hello)" -ge 1 ]]
}

t_enforcement() {   # a ':latest' Deployment must be denied on both clusters (dry run)
  local role out
  for role in stage production; do
    out="$(ocx "$role" create --dry-run=server -o name -f - 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lab-grader-probe
  namespace: default
spec:
  selector:
    matchLabels: {app: lab-grader-probe}
  template:
    metadata:
      labels: {app: lab-grader-probe}
    spec:
      containers:
        - name: probe
          image: ${APP_IMAGE}:latest
EOF
)" && return 1
    grep -q 'containerimagelatest' <<<"$out" || return 1
  done
}

# ------------------------------------------------------------------- main ---
echo "🔎 [LAB CHECK] Grading the Gatekeeper Lab..."
echo ""

require_hub
load_state
discover_clusters || exit 1
EXPECTED_CLUSTERS="$(printf '%s\n' "$STAGE_CLUSTER" "$PROD_CLUSTER" | sort | xargs)"

KUBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gk-check.XXXXXX")"
trap 'rm -rf -- "$KUBE_DIR"' EXIT
fetch_kubeconfig "$STAGE_CLUSTER" "$KUBE_DIR/stage.kubeconfig" || echo "   (stage checks will fail)"
fetch_kubeconfig "$PROD_CLUSTER" "$KUBE_DIR/production.kubeconfig" || echo "   (production checks will fail)"

echo "   🟡 Stage: ${STAGE_CLUSTER}    🔴 Production: ${PROD_CLUSTER}"
echo ""

check 5  "Namespace '${POLICY_NS}' exists on the hub" \
         "Step 2: oc new-project ${POLICY_NS}" \
         t_namespace
check 10 "Cluster set 'default' is bound to '${POLICY_NS}'" \
         "Step 4: Cluster sets > default > Namespace bindings > add ${POLICY_NS}" \
         t_binding
check 10 "Policy 'policy-gatekeeper-operator' (OperatorPolicy, Enforce) exists" \
         "Step 5: name/namespace must match exactly and Remediation must be 'Enforce'" \
         t_operator_policy
check 10 "Operator policy targets exactly the 2 managed clusters (not the hub)" \
         "Step 5: add the label expression environment = stage, production to the placement" \
         t_operator_placement
check 5  "Gatekeeper is installed and running on ${STAGE_CLUSTER} (stage)" \
         "Step 6: wait a few minutes, then check Governance > policy-gatekeeper-operator > Results" \
         t_operator_ready stage
check 5  "Gatekeeper is installed and running on ${PROD_CLUSTER} (production)" \
         "Step 6: wait a few minutes, then check Governance > policy-gatekeeper-operator > Results" \
         t_operator_ready production
check 10 "Namespace 'app-stage' is excluded from all constraints (through the policy)" \
         "Step 7: add the 'config:' block to the Gatekeeper object inside the policy with 'oc edit policy'" \
         t_exclusion
check 10 "Policy 'policy-gatekeeper-containerimage-latest' targets stage + production" \
         "Step 8: replace both CHANGE_ME values in policy-latest.yaml and run 'oc apply' again" \
         t_latest_placement
check 5  "Constraint 'containerimagelatest' is deployed on ${STAGE_CLUSTER}" \
         "Step 8: check the policy Results tab for errors" \
         t_constraint stage
check 5  "Constraint 'containerimagelatest' is deployed on ${PROD_CLUSTER}" \
         "Step 8: check the policy Results tab for errors" \
         t_constraint production
check 10 "stage-hello runs with ':latest' in the excluded 'app-stage' namespace" \
         "Step 9: oc-stage create -f stage-hello.yaml   (the exclusion from Step 7 must be in place first)" \
         t_stage_hello
check 10 "prod-hello runs in 'app-prod' with a pinned (non-latest) image tag" \
         "Step 10: change the image tag to v1.0 in prod-hello.yaml, delete the leftovers and create it again" \
         t_prod_hello
check 5  "Gatekeeper denies ':latest' on both clusters (live dry-run test)" \
         "Steps 6-8: Gatekeeper and the constraint must be active on both clusters" \
         t_enforcement

echo ""
echo "──────────────────────────────────────────────────────────────"
if [[ "$SCORE" -eq "$TOTAL" ]]; then
  echo "🏆 Score: ${SCORE}/${TOTAL}  -  Perfect! Gatekeeper is enforced across your fleet."
elif [[ "$SCORE" -ge "$PASS_SCORE" ]]; then
  echo "✅ Score: ${SCORE}/${TOTAL}  -  PASSED. Fix the ❌ items above for a perfect score."
else
  echo "❌ Score: ${SCORE}/${TOTAL}  -  NOT YET (${PASS_SCORE} needed). Follow the 👉 hints and run the check again."
fi
echo "──────────────────────────────────────────────────────────────"
