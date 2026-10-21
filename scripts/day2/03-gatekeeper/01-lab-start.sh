#!/usr/bin/env bash
# =============================================================================
#  Lab 3 - Integrate Gatekeeper with RHACM            | 01-lab-start.sh
# -----------------------------------------------------------------------------
#  Prepares the environment (equivalent of "lab start policies-integration"):
#   1. Verifies you are logged in to your ACM hub
#   2. Discovers your 2 managed clusters (sorted by name):
#        1st -> environment=stage      2nd -> environment=production
#      Override with:  STAGE_CLUSTER=<name> PROD_CLUSTER=<name> ./01-lab-start.sh
#   3. Pulls the admin kubeconfig of each managed cluster from the hub (Hive)
#   4. Labels the ManagedClusters and verifies the operator catalog
#   5. Generates the lab files in ~/lab-work/03-gatekeeper
# =============================================================================
set -uo pipefail

LAB_ID="03-gatekeeper"
WORK_DIR="${HOME}/lab-work/${LAB_ID}"
STATE_FILE="${WORK_DIR}/.lab-state"
POLICY_NS="policy-gatekeeper"
LAB_LABEL_KEY="workshop.rhacm.io/lab"
LAB_LABEL_VALUE="gatekeeper"
APP_IMAGE="${APP_IMAGE:-quay.io/redhattraining/hello-world-nginx}"
PINNED_TAG="${PINNED_TAG:-v1.0}"
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

env_label() { hub get managedcluster "$1" -o jsonpath='{.metadata.labels.environment}' 2>/dev/null; }

# Root policies on the hub (any namespace) that install the Gatekeeper operator
gatekeeper_policies() {
  local p
  for p in $(hub get policies.policy.open-cluster-management.io -A -l '!policy.open-cluster-management.io/root-policy' \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    hub get policies.policy.open-cluster-management.io "${p#*/}" -n "${p%%/*}" -o yaml 2>/dev/null \
      | grep "$OPERATOR_PACKAGE" >/dev/null && echo "$p"
  done
}

# ------------------------------------------------------------------- main ---
echo "🚀 [LAB START] Preparing environment for the Gatekeeper Lab..."
echo ""

require_hub
info "Logged in to the ACM hub as: $(hub whoami)"

load_state
discover_clusters || exit 1
[[ "$STAGE_CLUSTER" != "$PROD_CLUSTER" ]] || die "Stage and production must be two different clusters."

# --- 1. Managed clusters are healthy and in the 'default' cluster set ---------
for c in "$STAGE_CLUSTER" "$PROD_CLUSTER"; do
  hub get managedcluster "$c" >/dev/null 2>&1 || die "ManagedCluster '$c' does not exist on the hub."
  avail="$(hub get managedcluster "$c" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}')"
  [[ "$avail" == "True" ]] || die "ManagedCluster '$c' is not Available. Check Infrastructure > Clusters in the console."
  cset="$(hub get managedcluster "$c" -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/clusterset}')"
  [[ "$cset" == "default" ]] || die "Cluster '$c' is in cluster set '${cset:-<none>}', but this lab uses the 'default' set.
   Move it with: oc label managedcluster $c cluster.open-cluster-management.io/clusterset=default --overwrite"
done
info "Managed clusters are Available: ${STAGE_CLUSTER}, ${PROD_CLUSTER}"

# --- 2. Clean starting point -------------------------------------------------
if hub get namespace "$POLICY_NS" >/dev/null 2>&1; then
  die "Namespace '${POLICY_NS}' already exists on the hub (left over from a previous attempt).
   Run ./03-lab-finish.sh first, then run this script again."
fi
other_policies="$(gatekeeper_policies)"
if [[ -n "$other_policies" ]]; then
  die "Another RHACM policy already installs Gatekeeper on your fleet:
$(sed 's/^/      - /' <<<"$other_policies")
   It would keep re-installing Gatekeeper. Delete it (with its Placement and PlacementBinding),
   then run ./03-lab-finish.sh and this script again. Example:
      oc delete policy <name> -n <namespace>"
fi

# --- 3. Admin access to both managed clusters ----------------------------------
mkdir -p "$WORK_DIR/.kube"
chmod 700 "$WORK_DIR" "$WORK_DIR/.kube"
KUBE_DIR="$WORK_DIR/.kube"
fetch_kubeconfig "$STAGE_CLUSTER" "$KUBE_DIR/stage.kubeconfig" || exit 1
fetch_kubeconfig "$PROD_CLUSTER" "$KUBE_DIR/production.kubeconfig" || exit 1
info "Admin access to both managed clusters verified"

for role in stage production; do
  if ocx "$role" get crd gatekeepers.operator.gatekeeper.sh >/dev/null 2>&1; then
    die "Gatekeeper is already installed on the ${role} cluster (left over from a previous attempt).
   Run ./03-lab-finish.sh first, then run this script again."
  fi
  for ns in app-stage app-test app-prod; do
    ocx "$role" get namespace "$ns" >/dev/null 2>&1 \
      && die "Namespace '$ns' already exists on the ${role} cluster. Run ./03-lab-finish.sh first."
  done
done

# --- 4. The Gatekeeper operator is available in the catalog ------------------
CATALOG_SOURCE=""
for role in stage production; do
  sources="$(ocx "$role" get packagemanifests -n openshift-marketplace \
      -o jsonpath="{range .items[?(@.metadata.name==\"${OPERATOR_PACKAGE}\")]}{.status.catalogSource}{\"\\n\"}{end}" 2>/dev/null)"
  [[ -n "$sources" ]] || die "The '${OPERATOR_PACKAGE}' operator is not available in the catalog of the ${role} cluster."
  if grep -qx 'redhat-operators' <<<"$sources"; then src="redhat-operators"; else src="$(head -n1 <<<"$sources")"; fi
  [[ -z "$CATALOG_SOURCE" ]] && CATALOG_SOURCE="$src"
  [[ "$src" == "$CATALOG_SOURCE" ]] || warn "Catalog source differs between clusters (${CATALOG_SOURCE} vs ${src})"
done
info "Gatekeeper operator found in catalog source: ${CATALOG_SOURCE}"

# --- 5. Environment labels (previous values are saved for 03-lab-finish.sh) --
if [[ "$STATE_LOADED" -ne 1 ]]; then
  PREV_ENV_STAGE="$(env_label "$STAGE_CLUSTER")"
  PREV_ENV_PROD="$(env_label "$PROD_CLUSTER")"
  PREV_ENV_HUB="$(env_label local-cluster)"
fi
hub label managedcluster "$STAGE_CLUSTER" environment=stage --overwrite >/dev/null || die "Cannot label $STAGE_CLUSTER"
hub label managedcluster "$PROD_CLUSTER" environment=production --overwrite >/dev/null || die "Cannot label $PROD_CLUSTER"
hub_env="$(env_label local-cluster)"
if [[ "$hub_env" == "stage" || "$hub_env" == "production" ]]; then
  hub label managedcluster local-cluster environment- >/dev/null
  warn "Removed 'environment=${hub_env}' from local-cluster so the hub is not targeted (restored on finish)"
fi
info "Labeled ${STAGE_CLUSTER} environment=stage and ${PROD_CLUSTER} environment=production"

# --- 6. Demo image (checked from the bastion; non-fatal) ---------------------
for tag in latest "$PINNED_TAG"; do
  if ! oc image info "${APP_IMAGE}:${tag}" >/dev/null 2>&1; then
    warn "Could not verify ${APP_IMAGE}:${tag} from the bastion. If the app pods fail to pull, tell your instructor."
  fi
done

# --- 7. State file ------------------------------------------------------------
{
  printf 'STAGE_CLUSTER=%q\n'  "$STAGE_CLUSTER"
  printf 'PROD_CLUSTER=%q\n'   "$PROD_CLUSTER"
  printf 'CATALOG_SOURCE=%q\n' "$CATALOG_SOURCE"
  printf 'APP_IMAGE=%q\n'      "$APP_IMAGE"
  printf 'PINNED_TAG=%q\n'     "$PINNED_TAG"
  printf 'PREV_ENV_STAGE=%q\n' "${PREV_ENV_STAGE:-}"
  printf 'PREV_ENV_PROD=%q\n'  "${PREV_ENV_PROD:-}"
  printf 'PREV_ENV_HUB=%q\n'   "${PREV_ENV_HUB:-}"
} >"$STATE_FILE"

# --- 8. Lab files ----------------------------------------------------------------
cat >"$WORK_DIR/env.sh" <<EOF
# Load the lab helpers into your shell:   source ~/lab-work/${LAB_ID}/env.sh
#   oc       -> your ACM hub (unchanged)
#   oc-stage -> ${STAGE_CLUSTER} (environment=stage)
#   oc-prod  -> ${PROD_CLUSTER} (environment=production)
oc-stage() { oc --kubeconfig "${KUBE_DIR}/stage.kubeconfig" "\$@"; }
oc-prod()  { oc --kubeconfig "${KUBE_DIR}/production.kubeconfig" "\$@"; }
echo "🔧 Helpers loaded:  oc -> hub  |  oc-stage -> ${STAGE_CLUSTER}  |  oc-prod -> ${PROD_CLUSTER}"
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
  # No policy-level remediationAction on purpose: every template keeps its own
  # action, so the Gatekeeper constraint below stays in "deny" mode.
  policy-templates:
    # 1) Gatekeeper ConstraintTemplate - the rule logic (Rego)
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
    # 2) Gatekeeper Constraint - where the rule applies and what to do
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
    # 3) RHACM reporting - turns Gatekeeper admission denials into violations
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
            - key: CHANGE_ME          # TODO: the cluster label key
              operator: In
              values: [CHANGE_ME]     # TODO: the two environments to target
EOF

# Application manifests (Namespace + Deployment + Service + Route)
app_manifest() {   # $1 namespace  $2 app name  $3 image tag
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $1
  labels:
    ${LAB_LABEL_KEY}: ${LAB_LABEL_VALUE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $2
  namespace: $1
  labels:
    app: $2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $2
  template:
    metadata:
      labels:
        app: $2
    spec:
      containers:
        - name: $2
          image: ${APP_IMAGE}:$3
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
  name: $2
  namespace: $1
spec:
  selector:
    app: $2
  ports:
    - port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $2
  namespace: $1
spec:
  to:
    kind: Service
    name: $2
  port:
    targetPort: 8080
EOF
}
app_manifest app-stage stage-hello latest >"$WORK_DIR/stage-hello.yaml"
app_manifest app-test  hello-app   latest >"$WORK_DIR/hello-app.yaml"
app_manifest app-prod  prod-hello  latest >"$WORK_DIR/prod-hello.yaml"

echo ""
echo "✅ [LAB READY] Environment successfully primed!"
echo ""
echo "   🟡 Stage cluster      : ${STAGE_CLUSTER}   (environment=stage)"
echo "   🔴 Production cluster : ${PROD_CLUSTER}   (environment=production)"
echo "   📦 Operator catalog   : ${CATALOG_SOURCE}"
echo "   📁 Lab files          : ${WORK_DIR}"
echo ""
echo "👉 Next:  source ${WORK_DIR}/env.sh"
