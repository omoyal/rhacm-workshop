#!/usr/bin/env bash
# =============================================================================
#  Lab 4 - Compliance Operator with RHACM            | 02-check.sh
#  Grades the lab (score out of 100). Read-only: nothing is changed.
# =============================================================================
set -uo pipefail

LAB_DIR="${HOME}/DO0013L/labs/policies-compliance"
STATE_FILE="${LAB_DIR}/.lab-state"
POLICY_NS="policies-compliance"
CLUSTER_SET="apac"
PASS_SCORE=80

ENV_TARGET="${TARGET_CLUSTER:-}"
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

t_namespace() { hub get namespace "$POLICY_NS"; }
t_clusterset() { hub get managedclusterset "$CLUSTER_SET"; }
t_member() {
  [[ "$(hub get managedcluster "$TARGET_CLUSTER" \
        -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}' 2>/dev/null)" == "$CLUSTER_SET" ]]
}
t_binding() {
  [[ "$(hub get managedclustersetbindings.cluster.open-cluster-management.io "$CLUSTER_SET" -n "$POLICY_NS" \
        -o jsonpath='{.spec.clusterSet}' 2>/dev/null)" == "$CLUSTER_SET" ]]
}
t_operator_policy() {
  local yaml
  yaml="$(hub get policies.policy.open-cluster-management.io policy-complianceoperator -n "$POLICY_NS" -o yaml 2>/dev/null)" || return 1
  grep -E '^  remediationAction: enforce' <<<"$yaml" >/dev/null \
    && grep 'kind: OperatorPolicy' <<<"$yaml" >/dev/null \
    && grep 'compliance-operator' <<<"$yaml" >/dev/null
}
t_operator_placement() {
  local p; p="$(placement_of policy-complianceoperator)"
  [[ -n "$p" && "$(decisions_of "$p")" == "$TARGET_CLUSTER" ]]
}
t_operator_ready() {
  mc get csv -n openshift-compliance -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -E '^compliance-operator\.[^ ]+ Succeeded$' >/dev/null
}
t_e8_policy() {
  [[ "$(hub get policies.policy.open-cluster-management.io policy-e8-scan -n "$POLICY_NS" \
        -o jsonpath='{.spec.remediationAction}' 2>/dev/null)" == "enforce" ]]
}
t_e8_placement() {
  local p; p="$(placement_of policy-e8-scan)"
  [[ -n "$p" && "$(decisions_of "$p")" == "$TARGET_CLUSTER" ]]
}
t_scan_binding() { mc get scansettingbindings.compliance.openshift.io e8 -n openshift-compliance; }
t_suite() { mc get compliancesuites.compliance.openshift.io e8 -n openshift-compliance; }

echo "🔎 [LAB CHECK] Grading the Compliance Operator Lab on '${TARGET_CLUSTER}'..."
echo ""

command -v oc >/dev/null 2>&1 || die "The 'oc' CLI was not found."
hub whoami >/dev/null 2>&1 || die "You are not logged in. Log in to your ACM hub with 'oc login' and run again."
hub get crd managedclusters.cluster.open-cluster-management.io >/dev/null 2>&1 \
  || die "Your 'oc' session is not connected to the ACM hub. Log in to the hub and run again."

KUBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compliance-check.XXXXXX")"
trap 'rm -rf -- "$KUBE_DIR"' EXIT
cd_name="$(hub get clusterdeployments.hive.openshift.io -n "$TARGET_CLUSTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
secret="$(hub get clusterdeployments.hive.openshift.io "$cd_name" -n "$TARGET_CLUSTER" \
    -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' 2>/dev/null)"
( umask 077; hub extract "secret/${secret}" -n "$TARGET_CLUSTER" --keys=kubeconfig --to=- >"$KUBE_DIR/target.kubeconfig" 2>/dev/null ) \
  || echo "   ⚠️  Cannot reach '${TARGET_CLUSTER}' - its checks will fail."

check 5  "Project '${POLICY_NS}' exists on the hub" \
         "Step 1: oc new-project ${POLICY_NS}" \
         t_namespace
check 10 "Cluster set '${CLUSTER_SET}' exists" \
         "Step 2: Infrastructure > Clusters > Cluster sets > Create cluster set" \
         t_clusterset
check 10 "Cluster '${TARGET_CLUSTER}' is assigned to cluster set '${CLUSTER_SET}'" \
         "Step 2: ${CLUSTER_SET} > Actions > Manage resource assignments > select ${TARGET_CLUSTER}" \
         t_member
check 10 "Cluster set '${CLUSTER_SET}' is bound to namespace '${POLICY_NS}'" \
         "Step 2: ${CLUSTER_SET} > Namespace bindings (pencil icon) > select ${POLICY_NS}" \
         t_binding
check 15 "Policy 'policy-complianceoperator' installs the Compliance Operator (Enforce)" \
         "Step 3: check the name and namespace, and change the remediation to Enforce" \
         t_operator_policy
check 5  "Policy 'policy-complianceoperator' is placed on '${TARGET_CLUSTER}'" \
         "Step 3: in the placement, select the cluster set ${CLUSTER_SET}" \
         t_operator_placement
check 10 "The Compliance Operator is installed on '${TARGET_CLUSTER}'" \
         "Step 3: wait a few minutes and check the policy Results tab" \
         t_operator_ready
check 10 "Policy 'policy-e8-scan' exists with remediationAction: enforce" \
         "Step 5: set spec.remediationAction to enforce and create the policy in ${POLICY_NS}" \
         t_e8_policy
check 10 "Policy 'policy-e8-scan' is placed on '${TARGET_CLUSTER}'" \
         "Step 5: set matchLabels to cluster.open-cluster-management.io/clusterset: ${CLUSTER_SET}, then oc apply the file" \
         t_e8_placement
check 5  "ScanSettingBinding 'e8' was created on '${TARGET_CLUSTER}'" \
         "Step 5: the policy must be in enforce mode, and the Compliance Operator must be installed" \
         t_scan_binding
check 10 "The E8 scan (ComplianceSuite 'e8') runs on '${TARGET_CLUSTER}'" \
         "Step 6: wait a few minutes after creating the policy, then run the check again" \
         t_suite

phase="$(mc get compliancesuites.compliance.openshift.io e8 -n openshift-compliance -o jsonpath='{.status.phase}' 2>/dev/null)"
[[ -n "$phase" ]] && echo "" && echo "   ℹ️  E8 scan phase: ${phase}  (DONE = results are ready in Governance)"

echo ""
echo "──────────────────────────────────────────────────────────────"
if [[ "$SCORE" -eq "$TOTAL" ]]; then
  echo "🏆 Score: ${SCORE}/${TOTAL}  -  Perfect! Your cluster is being scanned for E8 compliance."
elif [[ "$SCORE" -ge "$PASS_SCORE" ]]; then
  echo "✅ Score: ${SCORE}/${TOTAL}  -  PASSED. Fix the ❌ items above for a perfect score."
else
  echo "❌ Score: ${SCORE}/${TOTAL}  -  NOT YET (${PASS_SCORE} needed). Follow the 👉 hints and run the check again."
fi
echo "──────────────────────────────────────────────────────────────"
