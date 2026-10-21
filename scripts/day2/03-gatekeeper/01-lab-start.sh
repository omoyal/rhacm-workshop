#!/usr/bin/env bash
# =============================================================================
#  Lab 3 - Gatekeeper with RHACM                      | 01-lab-start.sh
#  Prepares the environment on the hub and on the target managed cluster.
#  Target cluster: cluster1 (override: TARGET_CLUSTER=<name> ./01-lab-start.sh)
# =============================================================================
set -uo pipefail

LAB_ID="03-gatekeeper"
WORK_DIR="${HOME}/lab-work/${LAB_ID}"
STATE_FILE="${WORK_DIR}/.lab-state"
POLICY_NS="policy-gatekeeper"
TARGET_CLUSTER="${TARGET_CLUSTER:-cluster1}"
APP_IMAGE="${APP_IMAGE:-quay.io/redhattraining/hello-world-nginx}"
OPERATOR_PACKAGE="gatekeeper-operator-product"
LAB_LABEL_KEY="workshop.rhacm.io/lab"
LAB_LABEL_VALUE="gatekeeper"

die()  { echo "❌ [ERROR] $*" >&2; exit 1; }
info() { echo "   • $*"; }
warn() { echo "   ⚠️  $*"; }
hub()  { oc --request-timeout=30s "$@"; }
mc()   { oc --request-timeout=30s --kubeconfig "${WORK_DIR}/.kube/${TARGET_CLUSTER}.kubeconfig" "$@"; }

echo "🚀 [LAB START] Preparing environment for the Gatekeeper Lab..."
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
cset="$(hub get managedcluster "$TARGET_CLUSTER" -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}')"
[[ "$cset" == "default" ]] || die "Cluster '${TARGET_CLUSTER}' must be in the 'default' cluster set (current: '${cset:-none}')."
info "Managed cluster '${TARGET_CLUSTER}' is Available"

# --- Clean starting point ------------------------------------------------------
hub get namespace "$POLICY_NS" >/dev/null 2>&1 \
  && die "Namespace '${POLICY_NS}' already exists on the hub. Run ./03-lab-finish.sh first."

others=""
for p in $(hub get policies.policy.open-cluster-management.io -A -l '!policy.open-cluster-management.io/root-policy' \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  hub get policies.policy.open-cluster-management.io "${p#*/}" -n "${p%%/*}" -o yaml 2>/dev/null \
    | grep "$OPERATOR_PACKAGE" >/dev/null && others+="      - ${p}"$'\n'
done
[[ -z "$others" ]] || die "Another RHACM policy already installs Gatekeeper:
${others}   Delete it (oc delete policy <name> -n <namespace>), run ./03-lab-finish.sh, then run this script again."

# --- Admin access to the target cluster ----------------------------------------
mkdir -p "$WORK_DIR/.kube"
chmod 700 "$WORK_DIR" "$WORK_DIR/.kube"
cd_name="$(hub get clusterdeployments.hive.openshift.io -n "$TARGET_CLUSTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$cd_name" ]] || die "No ClusterDeployment found for '${TARGET_CLUSTER}'."
secret="$(hub get clusterdeployments.hive.openshift.io "$cd_name" -n "$TARGET_CLUSTER" \
    -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' 2>/dev/null)"
[[ -n "$secret" ]] || die "'${TARGET_CLUSTER}' has no admin kubeconfig."
( umask 077; hub extract "secret/${secret}" -n "$TARGET_CLUSTER" --keys=kubeconfig --to=- \
    >"$WORK_DIR/.kube/${TARGET_CLUSTER}.kubeconfig" 2>/dev/null ) || die "Cannot read the admin kubeconfig of '${TARGET_CLUSTER}'."
mc get clusterversion version -o name >/dev/null 2>&1 || die "The API of '${TARGET_CLUSTER}' is not reachable from the Bastion."
info "Admin access to '${TARGET_CLUSTER}' verified"

mc get crd gatekeepers.operator.gatekeeper.sh >/dev/null 2>&1 \
  && die "Gatekeeper is already installed on '${TARGET_CLUSTER}'. Run ./03-lab-finish.sh first."
mc get namespace app-prod >/dev/null 2>&1 \
  && die "Namespace 'app-prod' already exists on '${TARGET_CLUSTER}'. Run ./03-lab-finish.sh first."

sources="$(mc get packagemanifests -n openshift-marketplace \
    -o jsonpath="{range .items[?(@.metadata.name==\"${OPERATOR_PACKAGE}\")]}{.status.catalogSource}{\"\\n\"}{end}" 2>/dev/null)"
[[ -n "$sources" ]] || die "The Gatekeeper operator is not available in the catalog of '${TARGET_CLUSTER}'."
if grep -x 'redhat-operators' <<<"$sources" >/dev/null; then CATALOG_SOURCE="redhat-operators"; else CATALOG_SOURCE="$(head -n1 <<<"$sources")"; fi
info "Gatekeeper operator available from catalog: ${CATALOG_SOURCE}"

# --- Hub preparation -------------------------------------------------------------
for c in $(hub get managedclusters -l gatekeeper=enabled -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  [[ "$c" != "$TARGET_CLUSTER" ]] && hub label managedcluster "$c" gatekeeper- >/dev/null 2>&1
done
hub label managedcluster "$TARGET_CLUSTER" gatekeeper=enabled --overwrite >/dev/null \
  || die "Cannot label '${TARGET_CLUSTER}'."
hub create namespace "$POLICY_NS" >/dev/null || die "Cannot create namespace '${POLICY_NS}' on the hub."
info "Labeled '${TARGET_CLUSTER}' gatekeeper=enabled and created namespace '${POLICY_NS}'"

{
  printf 'TARGET_CLUSTER=%q\n' "$TARGET_CLUSTER"
  printf 'APP_IMAGE=%q\n' "$APP_IMAGE"
} >"$STATE_FILE"

# --- Lab files -------------------------------------------------------------------
cat >"$WORK_DIR/env.sh" <<EOF
# Usage: source ~/lab-work/${LAB_ID}/env.sh
oc-prod() { oc --kubeconfig "${WORK_DIR}/.kube/${TARGET_CLUSTER}.kubeconfig" "\$@"; }
echo "🔧 Ready:  oc -> ACM hub   |   oc-prod -> ${TARGET_CLUSTER}"
EOF

cat >"$WORK_DIR/policy-latest.yaml" <<'EOF'
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: policy-gatekeeper-containerimage-latest
  namespace: policy-gatekeeper
  annotations:
    policy.open-cluster-management.io/standards: NIST SP 800-53
    policy.open-cluster-management.io/categories: CM Configuration Management
    policy.open-cluster-management.io/controls: CM-2 Baseline Configuration
spec:
  disabled: false
  policy-templates:
    # 1) ConstraintTemplate: the rule logic, written in Rego
    - objectDefinition:
        apiVersion: templates.gatekeeper.sh/v1
        kind: ConstraintTemplate
        metadata:
          name: containerimagelatest
        spec:
          crd:
            spec:
              names:
                kind: ContainerImageLatest
          targets:
            - target: admission.k8s.gatekeeper.sh
              rego: |
                package containerimagelatest

                violation[{"msg": msg}] {
                  input.review.kind.kind == "Deployment"
                  container := input.review.object.spec.template.spec.containers[_]
                  endswith(container.image, ":latest")
                  msg := sprintf("%v/%v: container '%v' is using the latest tag for its image (%v), which is an anti-pattern.", [input.review.kind.kind, input.review.object.metadata.name, container.name, container.image])
                }
    # 2) Constraint: which resources the rule applies to, and the action (deny)
    - objectDefinition:
        apiVersion: constraints.gatekeeper.sh/v1beta1
        kind: ContainerImageLatest
        metadata:
          name: containerimagelatest
        spec:
          enforcementAction: deny
          match:
            kinds:
              - apiGroups: ["apps"]
                kinds: ["Deployment"]
    # 3) Reports every Gatekeeper denial as a violation in RHACM Governance
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: policy-gatekeeper-admission-latest
        spec:
          remediationAction: inform
          severity: low
          object-templates:
            - complianceType: mustnothave
              objectDefinition:
                apiVersion: v1
                kind: Event
                metadata:
                  namespace: openshift-gatekeeper-system
                  annotations:
                    constraint_action: deny
                    constraint_kind: ContainerImageLatest
                    constraint_name: containerimagelatest
                    event_type: violation
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: binding-policy-gatekeeper-containerimage-latest
  namespace: policy-gatekeeper
placementRef:
  name: placement-policy-gatekeeper-containerimage-latest
  kind: Placement
  apiGroup: cluster.open-cluster-management.io
subjects:
  - name: policy-gatekeeper-containerimage-latest
    kind: Policy
    apiGroup: policy.open-cluster-management.io
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: placement-policy-gatekeeper-containerimage-latest
  namespace: policy-gatekeeper
spec:
  clusterSets:
    - default
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchExpressions:
            - key: gatekeeper
              operator: In
              values: [enabled]
EOF

cat >"$WORK_DIR/prod-hello.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: app-prod
  labels:
    ${LAB_LABEL_KEY}: ${LAB_LABEL_VALUE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prod-hello
  namespace: app-prod
  labels:
    app: prod-hello
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prod-hello
  template:
    metadata:
      labels:
        app: prod-hello
    spec:
      containers:
        - name: prod-hello
          image: ${APP_IMAGE}:latest
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
---
apiVersion: v1
kind: Service
metadata:
  name: prod-hello
  namespace: app-prod
spec:
  selector:
    app: prod-hello
  ports:
    - port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: prod-hello
  namespace: app-prod
spec:
  to:
    kind: Service
    name: prod-hello
  port:
    targetPort: 8080
EOF

echo ""
echo "✅ [LAB READY] Environment successfully primed!"
echo ""
echo "   🎯 Target cluster   : ${TARGET_CLUSTER}  (label gatekeeper=enabled)"
echo "   📦 Operator catalog : ${CATALOG_SOURCE}"
echo "   📁 Lab files        : ${WORK_DIR}"
