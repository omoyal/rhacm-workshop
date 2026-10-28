#!/usr/bin/env bash
# =============================================================================
#  Lab 5 - Enable the RHACM Observability Stack        | 01-lab-start.sh
#  Prepares the environment for the lab:
#   - Installs OpenShift Data Foundation (Multicloud Object Gateway only) on
#     the hub, if it is not installed yet. This can take 10-15 minutes.
#   - Keeps observability on local-cluster and cluster1 only.
#   - Generates the lab files in ~/DO0014L/labs/observability-enable.
#  Target cluster: cluster1 (override: TARGET_CLUSTER=<name> ./01-lab-start.sh)
# =============================================================================
set -uo pipefail

LAB_DIR="${HOME}/DO0014L/labs/observability-enable"
STATE_FILE="${LAB_DIR}/.lab-state"
OBS_NS="open-cluster-management-observability"
ODF_NS="openshift-storage"
TARGET_CLUSTER="${TARGET_CLUSTER:-cluster1}"
OBS_LABEL_KEY="observability"

die()  { echo "❌ [ERROR] $*" >&2; exit 1; }
info() { echo "   • $*"; }
warn() { echo "   ⚠️  $*"; }
hub()  { oc --request-timeout=30s "$@"; }
mc()   { oc --request-timeout=30s --kubeconfig "${LAB_DIR}/.kube/${TARGET_CLUSTER}.kubeconfig" "$@"; }

wait_for() {   # timeout-seconds  description  command...
  local timeout="$1" desc="$2" waited=0
  shift 2
  printf '   ⏳ %s ' "$desc"
  until "$@" >/dev/null 2>&1; do
    if (( waited >= timeout )); then echo "timed out"; return 1; fi
    printf '.'
    sleep 10
    waited=$((waited + 10))
  done
  echo " ✔"
}

echo "🚀 [LAB START] Preparing environment for the Observability Lab..."
echo ""

# --- Hub login -----------------------------------------------------------------
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
info "Logged in to the ACM hub as: $(hub whoami)"

# --- Clean starting point ------------------------------------------------------
hub get multiclusterobservabilities.observability.open-cluster-management.io -o name 2>/dev/null | grep . >/dev/null \
  && die "Observability is already enabled on the hub (MultiClusterObservability exists). Run ./03-lab-finish.sh first."
hub get namespace "$OBS_NS" >/dev/null 2>&1 \
  && die "Namespace '${OBS_NS}' already exists on the hub. Run ./03-lab-finish.sh first."

# --- Target cluster ------------------------------------------------------------
hub get managedcluster "$TARGET_CLUSTER" >/dev/null 2>&1 || die "Managed cluster '${TARGET_CLUSTER}' was not found on the hub."
avail="$(hub get managedcluster "$TARGET_CLUSTER" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}')"
[[ "$avail" == "True" ]] || die "Managed cluster '${TARGET_CLUSTER}' is not Available."
[[ "$(hub get managedcluster "$TARGET_CLUSTER" -o jsonpath='{.metadata.labels.observability}')" == "disabled" ]] \
  && die "Cluster '${TARGET_CLUSTER}' already has the label observability=disabled. Run ./03-lab-finish.sh first."

mkdir -p "$LAB_DIR/.kube"
chmod 700 "$LAB_DIR/.kube"
cd_name="$(hub get clusterdeployments.hive.openshift.io -n "$TARGET_CLUSTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$cd_name" ]] || die "No ClusterDeployment found for '${TARGET_CLUSTER}'."
secret="$(hub get clusterdeployments.hive.openshift.io "$cd_name" -n "$TARGET_CLUSTER" \
    -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' 2>/dev/null)"
[[ -n "$secret" ]] || die "'${TARGET_CLUSTER}' has no admin kubeconfig."
( umask 077; hub extract "secret/${secret}" -n "$TARGET_CLUSTER" --keys=kubeconfig --to=- \
    >"$LAB_DIR/.kube/${TARGET_CLUSTER}.kubeconfig" 2>/dev/null ) || die "Cannot read the admin kubeconfig of '${TARGET_CLUSTER}'."
mc get clusterversion version -o name >/dev/null 2>&1 || die "The API of '${TARGET_CLUSTER}' is not reachable from the Bastion."
info "Managed cluster '${TARGET_CLUSTER}' is Available and reachable"

# --- Hub default StorageClass (needed by the object gateway and by observability)
DEFAULT_SC="$(hub get storageclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1)"
[[ -n "$DEFAULT_SC" ]] || die "The hub has no default StorageClass. Observability needs one. Tell your instructor."
info "Hub default StorageClass: ${DEFAULT_SC}"

# --- OpenShift Data Foundation: Multicloud Object Gateway on the hub ------------
noobaa_ready() { [[ "$(hub get noobaa noobaa -n "$ODF_NS" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Ready" ]]; }
sc_ready()     { hub get storageclass openshift-storage.noobaa.io >/dev/null 2>&1; }
cluster_ready(){ [[ "$(hub get storagecluster ocs-storagecluster -n "$ODF_NS" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Ready" ]]; }
odf_ready()    { noobaa_ready && sc_ready && cluster_ready; }
csvs_ready() {
  local phases
  phases="$(hub get csv -n "$ODF_NS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null)"
  grep -E '^odf-operator\.[^ ]+ Succeeded$' <<<"$phases" >/dev/null || return 1
  ! grep -v ' Succeeded$' <<<"$phases" | grep . >/dev/null
}

ODF_BY_LAB="no"
if odf_ready; then
  info "OpenShift Data Foundation (Multicloud Object Gateway) is already installed and Ready"
else
  if ! hub get crd storageclusters.ocs.openshift.io >/dev/null 2>&1; then
    channel="$(hub get packagemanifest odf-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}' 2>/dev/null)"
    catsrc="$(hub get packagemanifest odf-operator -n openshift-marketplace -o jsonpath='{.status.catalogSource}' 2>/dev/null)"
    [[ -n "$channel" && -n "$catsrc" ]] || die "The OpenShift Data Foundation operator is not available in the hub catalog."
    info "Installing OpenShift Data Foundation (channel ${channel}, catalog ${catsrc}) - this takes several minutes"
    hub apply -f - >/dev/null <<EOF || die "Cannot create the OpenShift Data Foundation namespace or subscription."
apiVersion: v1
kind: Namespace
metadata:
  name: ${ODF_NS}
  labels:
    openshift.io/cluster-monitoring: "true"
EOF
    if [[ -z "$(hub get operatorgroups -n "$ODF_NS" -o name 2>/dev/null)" ]]; then
      hub apply -f - >/dev/null <<EOF || die "Cannot create the OperatorGroup in '${ODF_NS}'."
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: ${ODF_NS}
spec:
  targetNamespaces:
    - ${ODF_NS}
EOF
    fi
    hub apply -f - >/dev/null <<EOF || die "Cannot create the OpenShift Data Foundation subscription."
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: ${ODF_NS}
spec:
  name: odf-operator
  channel: ${channel}
  source: ${catsrc}
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    ODF_BY_LAB="yes"
  fi
  wait_for 900 "Waiting for the OpenShift Data Foundation operators" csvs_ready \
    || die "OpenShift Data Foundation did not finish installing. Check Operators > Installed Operators in project '${ODF_NS}', then run this script again."
  wait_for 300 "Waiting for the StorageCluster API" hub get crd storageclusters.ocs.openshift.io \
    || die "The StorageCluster API is not available."
  if ! hub get storagecluster ocs-storagecluster -n "$ODF_NS" >/dev/null 2>&1; then
    hub apply -f - >/dev/null <<EOF || die "Cannot create the Multicloud Object Gateway StorageCluster."
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: ${ODF_NS}
spec:
  multiCloudGateway:
    dbStorageClassName: ${DEFAULT_SC}
    reconcileStrategy: standalone
EOF
    ODF_BY_LAB="yes"
  fi
  wait_for 1200 "Waiting for the Multicloud Object Gateway (NooBaa) to be Ready" odf_ready \
    || die "The Multicloud Object Gateway is not Ready yet. Check 'oc get noobaa -n ${ODF_NS}', then run this script again."
  info "OpenShift Data Foundation (Multicloud Object Gateway) is Ready"
fi

# --- Observability only on local-cluster and the target cluster -----------------
DISABLED_BY_LAB=""
for c in $(hub get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  [[ "$c" == "local-cluster" || "$c" == "$TARGET_CLUSTER" ]] && continue
  [[ "$(hub get managedcluster "$c" -o jsonpath='{.metadata.labels.local-cluster}' 2>/dev/null)" == "true" ]] && continue
  if [[ "$(hub get managedcluster "$c" -o jsonpath='{.metadata.labels.observability}' 2>/dev/null)" != "disabled" ]]; then
    hub label managedcluster "$c" "${OBS_LABEL_KEY}=disabled" --overwrite >/dev/null 2>&1 && DISABLED_BY_LAB+="$c "
  fi
done
[[ -n "$DISABLED_BY_LAB" ]] && info "Observability will collect metrics from local-cluster and ${TARGET_CLUSTER} only"

# --- State and lab files ---------------------------------------------------------
{
  printf 'TARGET_CLUSTER=%q\n' "$TARGET_CLUSTER"
  printf 'DISABLED_BY_LAB=%q\n' "${DISABLED_BY_LAB% }"
  printf 'ODF_BY_LAB=%q\n' "$ODF_BY_LAB"
} >"$STATE_FILE"

cat >"$LAB_DIR/env.sh" <<EOF
# Usage: source ~/DO0014L/labs/observability-enable/env.sh
oc-${TARGET_CLUSTER}() { oc --kubeconfig "${LAB_DIR}/.kube/${TARGET_CLUSTER}.kubeconfig" "\$@"; }
echo "🔧 Ready:  oc -> ACM hub   |   oc-${TARGET_CLUSTER} -> ${TARGET_CLUSTER}"
EOF

cat >"$LAB_DIR/obc.yaml" <<'EOF'
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: thanos-obc
  namespace: CHANGE_ME_NAMESPACE
spec:
  storageClassName: CHANGE_ME_STORAGE_CLASS
  generateBucketName: observability-bucket
EOF

cat >"$LAB_DIR/secret.yaml" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: thanos-object-storage
  namespace: open-cluster-management-observability
type: Opaque
stringData:
  thanos.yaml: |
    type: s3
    config:
      bucket: CHANGE_ME_BUCKET_NAME
      endpoint: CHANGE_ME_S3_ROUTE_HOST
      insecure: true
      access_key: CHANGE_ME_AWS_ACCESS_KEY_ID
      secret_key: CHANGE_ME_AWS_SECRET_ACCESS_KEY
EOF

cat >"$LAB_DIR/mcobs.yaml" <<EOF
apiVersion: observability.open-cluster-management.io/v1beta2
kind: MultiClusterObservability
metadata:
  name: observability
spec:
  observabilityAddonSpec:
    enableMetrics: CHANGE_ME_TRUE_OR_FALSE
  storageConfig:
    metricObjectStorage:
      key: thanos.yaml
      name: CHANGE_ME_SECRET_NAME
    storageClass: ${DEFAULT_SC}
    alertmanagerStorageSize: 1Gi
    compactStorageSize: 1Gi
    receiveStorageSize: 1Gi
    ruleStorageSize: 1Gi
    storeStorageSize: 1Gi
EOF

echo ""
echo "✅ [LAB READY] Environment successfully primed!"
echo ""
echo "   🎯 Managed cluster  : ${TARGET_CLUSTER}"
echo "   🗄️  Object storage   : OpenShift Data Foundation - Multicloud Object Gateway"
echo "   📁 Lab files        : ${LAB_DIR}"
