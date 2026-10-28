#!/usr/bin/env bash
# =============================================================================
#  Lab 4 - Compliance Operator with RHACM            | 01-lab-start.sh
#  Prepares the environment for the lab.
#  Target cluster: cluster1 (override: TARGET_CLUSTER=<name> ./01-lab-start.sh)
# =============================================================================
set -uo pipefail

LAB_DIR="${HOME}/DO0013L/labs/policies-compliance"
STATE_FILE="${LAB_DIR}/.lab-state"
POLICY_NS="policies-compliance"
CLUSTER_SET="apac"
TARGET_CLUSTER="${TARGET_CLUSTER:-cluster1}"
OPERATOR_PACKAGE="compliance-operator"

die()  { echo "❌ [ERROR] $*" >&2; exit 1; }
info() { echo "   • $*"; }
warn() { echo "   ⚠️  $*"; }
hub()  { oc --request-timeout=30s "$@"; }
mc()   { oc --request-timeout=30s --kubeconfig "${KUBE_DIR}/target.kubeconfig" "$@"; }

echo "🚀 [LAB START] Preparing environment for the Compliance Operator Lab..."
echo ""

# --- Hub login -----------------------------------------------------------------
command -v oc >/dev/null 2>&1 || die "The 'oc' CLI was not found."
hub whoami >/dev/null 2>&1 || die "You are not logged in. Log in to your ACM hub with 'oc login' and run again."
hub get crd managedclusters.cluster.open-cluster-management.io >/dev/null 2>&1 \
  || die "Your 'oc' session is not connected to the ACM hub. Log in to the hub and run again."
info "Logged in to the ACM hub as: $(hub whoami)"

# --- Target cluster ------------------------------------------------------------
hub get managedcluster "$TARGET_CLUSTER" >/dev/null 2>&1 || die "Managed cluster '${TARGET_CLUSTER}' was not found on the hub."
avail="$(hub get managedcluster "$TARGET_CLUSTER" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}')"
[[ "$avail" == "True" ]] || die "Managed cluster '${TARGET_CLUSTER}' is not Available."
CURRENT_SET="$(hub get managedcluster "$TARGET_CLUSTER" -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}')"
info "Managed cluster '${TARGET_CLUSTER}' is Available (cluster set: ${CURRENT_SET:-none})"

# --- Clean starting point ------------------------------------------------------
hub get namespace "$POLICY_NS" >/dev/null 2>&1 \
  && die "Namespace '${POLICY_NS}' already exists on the hub. Run ./03-lab-finish.sh first."
hub get managedclusterset "$CLUSTER_SET" >/dev/null 2>&1 \
  && die "Cluster set '${CLUSTER_SET}' already exists on the hub. Run ./03-lab-finish.sh first."
[[ "$CURRENT_SET" == "$CLUSTER_SET" ]] \
  && die "Cluster '${TARGET_CLUSTER}' is already in cluster set '${CLUSTER_SET}'. Run ./03-lab-finish.sh first."

others=""
for p in $(hub get policies.policy.open-cluster-management.io -A -l '!policy.open-cluster-management.io/root-policy' \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  hub get policies.policy.open-cluster-management.io "${p#*/}" -n "${p%%/*}" -o yaml 2>/dev/null \
    | grep -E "name: ${OPERATOR_PACKAGE}\$|kind: ScanSettingBinding" >/dev/null && others+="      - ${p}"$'\n'
done
[[ -z "$others" ]] || die "Another RHACM policy already manages the Compliance Operator:
${others}   Delete it (oc delete policy <name> -n <namespace>), run ./03-lab-finish.sh, then run this script again."

# --- Admin access to the target cluster ----------------------------------------
KUBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compliance-start.XXXXXX")"
trap 'rm -rf -- "$KUBE_DIR"' EXIT
cd_name="$(hub get clusterdeployments.hive.openshift.io -n "$TARGET_CLUSTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$cd_name" ]] || die "No ClusterDeployment found for '${TARGET_CLUSTER}'."
secret="$(hub get clusterdeployments.hive.openshift.io "$cd_name" -n "$TARGET_CLUSTER" \
    -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' 2>/dev/null)"
[[ -n "$secret" ]] || die "'${TARGET_CLUSTER}' has no admin kubeconfig."
( umask 077; hub extract "secret/${secret}" -n "$TARGET_CLUSTER" --keys=kubeconfig --to=- \
    >"$KUBE_DIR/target.kubeconfig" 2>/dev/null ) || die "Cannot read the admin kubeconfig of '${TARGET_CLUSTER}'."
mc get clusterversion version -o name >/dev/null 2>&1 || die "The API of '${TARGET_CLUSTER}' is not reachable from the Bastion."
info "Admin access to '${TARGET_CLUSTER}' verified"

mc get crd compliancesuites.compliance.openshift.io >/dev/null 2>&1 \
  && die "The Compliance Operator is already installed on '${TARGET_CLUSTER}'. Run ./03-lab-finish.sh first."

sources="$(mc get packagemanifests -n openshift-marketplace \
    -o jsonpath="{range .items[?(@.metadata.name==\"${OPERATOR_PACKAGE}\")]}{.status.catalogSource}{\"\\n\"}{end}" 2>/dev/null)"
[[ -n "$sources" ]] || die "The Compliance Operator is not available in the catalog of '${TARGET_CLUSTER}'."
if grep -x 'redhat-operators' <<<"$sources" >/dev/null; then CATALOG_SOURCE="redhat-operators"; else CATALOG_SOURCE="$(head -n1 <<<"$sources")"; fi
info "Compliance Operator available from catalog: ${CATALOG_SOURCE}"

default_sc="$(mc get storageclass \
    -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null \
  | grep -c '^true$')"
if [[ "$default_sc" -ge 1 ]]; then
  info "Default StorageClass found on '${TARGET_CLUSTER}' (needed to store scan results)"
else
  warn "No default StorageClass on '${TARGET_CLUSTER}'. The E8 scan will not complete. Tell your instructor."
fi

# --- Lab files -------------------------------------------------------------------
mkdir -p "$LAB_DIR"
{
  printf 'TARGET_CLUSTER=%q\n' "$TARGET_CLUSTER"
  printf 'PREV_CLUSTERSET=%q\n' "${CURRENT_SET:-default}"
} >"$STATE_FILE"

cat >"$LAB_DIR/policy-compliance-operator-e8-scan.yaml" <<'EOF'
# This policy assumes that the Compliance Operator is installed and running on
# the managed clusters. It deploys a scan that checks the control plane and
# worker nodes, and verifies compliance with the E8 (Essential 8) profile.
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: policy-e8-scan
  annotations:
    policy.open-cluster-management.io/standards: NIST SP 800-53
    policy.open-cluster-management.io/categories: CM Configuration Management
    policy.open-cluster-management.io/controls: CM-6 Configuration Settings
spec:
  remediationAction: inform
  disabled: false
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: compliance-e8-scan
        spec:
          remediationAction: inform
          severity: high
          object-templates:
            - complianceType: musthave # this template creates ScanSettingBinding:e8
              objectDefinition:
                apiVersion: compliance.openshift.io/v1alpha1
                kind: ScanSettingBinding
                metadata:
                  name: e8
                  namespace: openshift-compliance
                profiles:
                  - apiGroup: compliance.openshift.io/v1alpha1
                    kind: Profile
                    name: ocp4-e8
                  - apiGroup: compliance.openshift.io/v1alpha1
                    kind: Profile
                    name: rhcos4-e8
                settingsRef:
                  apiGroup: compliance.openshift.io/v1alpha1
                  kind: ScanSetting
                  name: default
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: compliance-suite-e8
        spec:
          remediationAction: InformOnly
          severity: high
          object-templates:
            - complianceType: musthave # this template checks if the scan has completed by checking the status field
              objectDefinition:
                apiVersion: compliance.openshift.io/v1alpha1
                kind: ComplianceSuite
                metadata:
                  name: e8
                  namespace: openshift-compliance
                status:
                  phase: DONE
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: compliance-suite-e8-results
        spec:
          remediationAction: InformOnly
          severity: high
          object-templates:
            - complianceType: mustnothave # this template reports the results of the e8 scan suite by looking at ComplianceCheckResult CRs
              objectDefinition:
                apiVersion: compliance.openshift.io/v1alpha1
                kind: ComplianceCheckResult
                metadata:
                  namespace: openshift-compliance
                  labels:
                    compliance.openshift.io/check-status: FAIL
                    compliance.openshift.io/suite: e8
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: binding-policy-e8-scan
placementRef:
  name: placement-policy-e8-scan
  kind: Placement
  apiGroup: cluster.open-cluster-management.io
subjects:
  - name: policy-e8-scan
    kind: Policy
    apiGroup: policy.open-cluster-management.io
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: placement-policy-e8-scan
spec:
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchLabels:
            environment: dev
EOF

echo ""
echo "✅ [LAB READY] Environment successfully primed!"
echo ""
echo "   🎯 Target cluster   : ${TARGET_CLUSTER}"
echo "   📦 Operator catalog : ${CATALOG_SOURCE}"
echo "   📁 Lab files        : ${LAB_DIR}"
