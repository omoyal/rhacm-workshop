#!/usr/bin/env bash
# =============================================================================
#  Lab 5 - Enable the RHACM Observability Stack        | 02-check.sh
#  Grades the lab (score out of 100). Read-only: nothing is changed.
# =============================================================================
set -uo pipefail

LAB_DIR="${HOME}/DO0014L/labs/observability-enable"
STATE_FILE="${LAB_DIR}/.lab-state"
OBS_NS="open-cluster-management-observability"
PASS_SCORE=80

ENV_TARGET="${TARGET_CLUSTER:-}"
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
TARGET_CLUSTER="${ENV_TARGET:-${TARGET_CLUSTER:-cluster1}}"

die() { echo "❌ [ERROR] $*" >&2; exit 1; }
hub() { oc --request-timeout=30s "$@"; }
mc()  { oc --request-timeout=30s --kubeconfig "${KUBE_DIR}/target.kubeconfig" "$@"; }

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

thanos_field() {   # key in thanos.yaml (bucket, endpoint, access_key, secret_key)
  hub extract secret/thanos-object-storage -n "$OBS_NS" --keys=thanos.yaml --to=- 2>/dev/null \
    | awk -v k="$1" '$1 == k":" {print $2; exit}'
}

t_namespace() { hub get namespace "$OBS_NS"; }
t_pull_secret() {
  [[ "$(hub get secret multiclusterhub-operator-pull-secret -n "$OBS_NS" -o jsonpath='{.type}' 2>/dev/null)" == "kubernetes.io/dockerconfigjson" ]]
}
t_obc() {
  [[ "$(hub get objectbucketclaim thanos-obc -n "$OBS_NS" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Bound" ]]
}
t_thanos_secret() {
  local bucket key route
  bucket="$(hub get configmap thanos-obc -n "$OBS_NS" -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null)"
  key="$(hub extract secret/thanos-obc -n "$OBS_NS" --keys=AWS_ACCESS_KEY_ID --to=- 2>/dev/null)"
  route="$(hub get route s3 -n openshift-storage -o jsonpath='{.spec.host}' 2>/dev/null)"
  [[ -n "$bucket" && "$(thanos_field bucket)" == "$bucket" ]] || return 1
  [[ -n "$key" && "$(thanos_field access_key)" == "$key" ]] || return 1
  [[ -n "$route" && "$(thanos_field endpoint)" == "$route" ]]
}
t_mco() {
  [[ "$(hub get multiclusterobservability observability -o jsonpath='{.spec.observabilityAddonSpec.enableMetrics}' 2>/dev/null)" == "true" ]] \
  && [[ "$(hub get multiclusterobservability observability -o jsonpath='{.spec.storageConfig.metricObjectStorage.name}' 2>/dev/null)" == "thanos-object-storage" ]]
}
t_mco_ready() {
  [[ "$(hub get multiclusterobservability observability -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]
}
t_grafana() {
  local n
  n="$(hub get deployment observability-grafana -n "$OBS_NS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  [[ "${n:-0}" -ge 1 ]]
}
t_label() {
  [[ "$(hub get managedcluster "$TARGET_CLUSTER" -o jsonpath='{.metadata.labels.observability}' 2>/dev/null)" == "disabled" ]]
}
t_no_addon_pods() {
  t_mco && t_label || return 1
  mc get namespace >/dev/null || return 1
  [[ -z "$(mc get pods -n open-cluster-management-addon-observability -o name 2>/dev/null)" ]]
}

echo "🔎 [LAB CHECK] Grading the Observability Lab..."
echo ""

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

KUBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/obs-check.XXXXXX")"
trap 'rm -rf -- "$KUBE_DIR"' EXIT
cd_name="$(hub get clusterdeployments.hive.openshift.io -n "$TARGET_CLUSTER" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
secret="$(hub get clusterdeployments.hive.openshift.io "$cd_name" -n "$TARGET_CLUSTER" \
    -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}' 2>/dev/null)"
( umask 077; hub extract "secret/${secret}" -n "$TARGET_CLUSTER" --keys=kubeconfig --to=- >"$KUBE_DIR/target.kubeconfig" 2>/dev/null ) \
  || echo "   ⚠️  Cannot reach '${TARGET_CLUSTER}' - its checks will fail."

check 5  "Namespace '${OBS_NS}' exists on the hub" \
         "Step 1: oc create namespace ${OBS_NS}" \
         t_namespace
check 10 "Secret 'multiclusterhub-operator-pull-secret' exists (dockerconfigjson)" \
         "Step 2: extract the pull-secret and create the secret with --type=kubernetes.io/dockerconfigjson" \
         t_pull_secret
check 10 "ObjectBucketClaim 'thanos-obc' is Bound" \
         "Step 4: set the namespace and storageClassName in obc.yaml, then oc apply -f obc.yaml" \
         t_obc
check 15 "Secret 'thanos-object-storage' has the right bucket, endpoint and access key" \
         "Steps 5-6: copy BUCKET_NAME, the s3 route host and the keys into secret.yaml, then oc apply -f secret.yaml" \
         t_thanos_secret
check 10 "MultiClusterObservability 'observability' is configured" \
         "Step 7: set enableMetrics: true and name: thanos-object-storage in mcobs.yaml, then oc apply -f mcobs.yaml" \
         t_mco
check 15 "The observability service is Ready" \
         "Step 7: wait a few minutes, then check: oc get pods -n ${OBS_NS}" \
         t_mco_ready
check 5  "Grafana is running" \
         "Step 7: wait a few minutes, then check: oc get pods -n ${OBS_NS}" \
         t_grafana
check 15 "Metrics collection is disabled on '${TARGET_CLUSTER}' (observability=disabled)" \
         "Step 9: oc label managedcluster ${TARGET_CLUSTER} observability=disabled" \
         t_label
check 15 "No observability add-on pods run on '${TARGET_CLUSTER}'" \
         "Step 9: after the label is set, the add-on is removed within a few minutes" \
         t_no_addon_pods

echo ""
echo "──────────────────────────────────────────────────────────────"
if [[ "$SCORE" -eq "$TOTAL" ]]; then
  echo "🏆 Score: ${SCORE}/${TOTAL}  -  Perfect! Observability is enabled across your fleet."
elif [[ "$SCORE" -ge "$PASS_SCORE" ]]; then
  echo "✅ Score: ${SCORE}/${TOTAL}  -  PASSED. Fix the ❌ items above for a perfect score."
else
  echo "❌ Score: ${SCORE}/${TOTAL}  -  NOT YET (${PASS_SCORE} needed). Follow the 👉 hints and run the check again."
fi
echo "──────────────────────────────────────────────────────────────"
