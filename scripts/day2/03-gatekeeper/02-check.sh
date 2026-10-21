#!/usr/bin/env bash
# =============================================================================
#  Lab 3 - Gatekeeper with RHACM                      | 02-check.sh
#  Grades the lab (score out of 100). Read-only: nothing is changed.
# =============================================================================
set -uo pipefail

LAB_ID="03-gatekeeper"
WORK_DIR="${HOME}/lab-work/${LAB_ID}"
STATE_FILE="${WORK_DIR}/.lab-state"
POLICY_NS="policy-gatekeeper"
PASS_SCORE=80

ENV_TARGET="${TARGET_CLUSTER:-}"
APP_IMAGE="quay.io/redhattraining/hello-world-nginx"
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
TARGET_CLUSTER="${ENV_TARGET:-${TARGET_CLUSTER:-cluster1}}"

die() { echo "❌ [ERROR] $*" >&2; exit 1; }
hub() { oc --request-timeout=30s "$@"; }
mc()  { oc --request-timeout=30s --kubeconfig "${KUBE_DIR}/target.kubeconfig" "$@"; }

placement_of() {   # policy name -> Placement name (through its PlacementBinding)
  hub get placementbindings.policy.open-cluster-management.io -n "$POLICY_NS" \
      -o jsonpath='{range .items[*]}{.placementRef.name}{" "}{.subjects[*].name}{"\n"}{end}' 2>/dev/null \
    | awk -v p="$1" '{for (i = 2; i <= NF; i++) if ($i == p) {print $1; exit}}'
}
decisions_of() {   # Placement name -> selected clusters
  hub get placementdecisions.cluster.open-cluster-management.io -n "$POLICY_NS" \
      -l "cluster.open-cluster-management.io/placement=$1" \
      -o jsonpath='{.items[*].status.decisions[*].clusterName}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sort -u | xargs
}
ready_replicas() { local n; n="$(mc get deployment "$2" -n "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"; echo "${n:-0}"; }

SCORE=0
TOTAL=0
check() {   # weight  description  hint  command...
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

t_binding() {
  [[ "$(hub get managedclustersetbindings.cluster.open-cluster-management.io default -n "$POLICY_NS" \
        -o jsonpath='{.spec.clusterSet}' 2>/dev/null)" == "default" ]]
}
t_operator_policy() {
  local yaml
  yaml="$(hub get policies.policy.open-cluster-management.io policy-gatekeeper-operator -n "$POLICY_NS" -o yaml 2>/dev/null)" || return 1
  grep -E '^  remediationAction: enforce' <<<"$yaml" >/dev/null && grep 'kind: OperatorPolicy' <<<"$yaml" >/dev/null
}
t_operator_placement() {
  local p; p="$(placement_of policy-gatekeeper-operator)"
  [[ -n "$p" && "$(decisions_of "$p")" == "$TARGET_CLUSTER" ]]
}
t_gatekeeper_running() {
  mc get csv -n openshift-operators -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -E '^gatekeeper-operator-product\.[^ ]+ Succeeded$' >/dev/null || return 1
  [[ "$(ready_replicas openshift-gatekeeper-system gatekeeper-controller-manager)" -ge 1 ]]
}
t_latest_policy() {
  local p; p="$(placement_of policy-gatekeeper-containerimage-latest)"
  [[ -n "$p" && "$(decisions_of "$p")" == "$TARGET_CLUSTER" ]]
}
t_constraint() {
  mc get constrainttemplates.templates.gatekeeper.sh containerimagelatest && \
  mc get containerimagelatest.constraints.gatekeeper.sh containerimagelatest
}
t_prod_hello() {
  local img
  img="$(mc get deployment prod-hello -n app-prod -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  [[ -n "$img" && "$img" != *:latest && "$(ready_replicas app-prod prod-hello)" -ge 1 ]]
}
t_enforcement() {
  local out
  out="$(mc create --dry-run=server -o name -f - 2>&1 <<EOF
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
  grep 'containerimagelatest' <<<"$out" >/dev/null
}

echo "🔎 [LAB CHECK] Grading the Gatekeeper Lab on '${TARGET_CLUSTER}'..."
echo ""

command -v oc >/dev/null 2>&1 || die "The 'oc' CLI was not found."
hub whoami >/dev/null 2>&1 || die "You are not logged in. Log in to your ACM hub with 'oc login' and run again."
hub get crd managedclusters.cluster.open-cluster-management.io >/dev/null 2>&1 \
  || die "Your 'oc' session is not connected to the ACM hub. Log in to the hub and run again."

KUBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gk-check.XXXXXX")"
trap 'rm -rf -- "$KUBE_DIR"' EXIT
cd_name="$(hub get clusterdeployments.hive.openshift.io -n "$TARGET_CLUSTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
secret="$(hub get clusterdeployments.hive.openshift.io "$cd_name" -n "$TARGET_CLUSTER" \
    -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' 2>/dev/null)"
( umask 077; hub extract "secret/${secret}" -n "$TARGET_CLUSTER" --keys=kubeconfig --to=- >"$KUBE_DIR/target.kubeconfig" 2>/dev/null ) \
  || echo "   ⚠️  Cannot reach '${TARGET_CLUSTER}' - its checks will fail."

check 10 "Cluster set 'default' is bound to namespace '${POLICY_NS}'" \
         "Step 2: Cluster sets > default > Namespace bindings > add ${POLICY_NS}" \
         t_binding
check 15 "Policy 'policy-gatekeeper-operator' exists (Operator policy, Enforce)" \
         "Step 3: check the policy name, the namespace, and that Remediation is 'Enforce'" \
         t_operator_policy
check 15 "The operator policy targets only '${TARGET_CLUSTER}'" \
         "Step 3: in the placement, add the label expression gatekeeper = enabled" \
         t_operator_placement
check 15 "Gatekeeper is installed and running on '${TARGET_CLUSTER}'" \
         "Step 4: wait a few minutes and check the policy Results tab" \
         t_gatekeeper_running
check 10 "Policy 'policy-gatekeeper-containerimage-latest' is placed on '${TARGET_CLUSTER}'" \
         "Step 5: oc apply -f policy-latest.yaml" \
         t_latest_policy
check 10 "Constraint 'containerimagelatest' is deployed on '${TARGET_CLUSTER}'" \
         "Step 5: check the policy Results tab for errors" \
         t_constraint
check 15 "prod-hello runs in 'app-prod' with a pinned image tag" \
         "Step 6: set the image tag to v1.0 in prod-hello.yaml, delete the leftovers and create it again" \
         t_prod_hello
check 10 "Gatekeeper denies ':latest' images (live test)" \
         "Steps 4-5: Gatekeeper and the constraint must both be active" \
         t_enforcement

echo ""
echo "──────────────────────────────────────────────────────────────"
if [[ "$SCORE" -eq "$TOTAL" ]]; then
  echo "🏆 Score: ${SCORE}/${TOTAL}  -  Perfect! Gatekeeper is enforcing your policy."
elif [[ "$SCORE" -ge "$PASS_SCORE" ]]; then
  echo "✅ Score: ${SCORE}/${TOTAL}  -  PASSED. Fix the ❌ items above for a perfect score."
else
  echo "❌ Score: ${SCORE}/${TOTAL}  -  NOT YET (${PASS_SCORE} needed). Follow the 👉 hints and run the check again."
fi
echo "──────────────────────────────────────────────────────────────"
