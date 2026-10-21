#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rhacm-gatekeeper-lab"
STAGE_CLUSTER="cluster2-sno"
PROD_CLUSTER="cluster1"
OWNER_LABEL="workshop.rhacm.io/owner"
OWNER_VALUE="gatekeeper-lab"
die() { echo "ERROR: $*" >&2; exit 1; }
# Use the active hub login. Never modify the user's kubeconfig.
set +x
command -v oc >/dev/null || { echo "ERROR: oc is required." >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 is required." >&2; exit 1; }
HUB_CONTEXT=hub
STAGE_CONTEXT=stage
PROD_CONTEXT=production
HUB_LOGIN="$(oc config current-context)" || exit 1
oc --context "$HUB_LOGIN" get managedcluster cluster1 cluster2-sno -o name >/dev/null || {
  echo "ERROR: Run from the workshop terminal logged in to your ACM hub, with access to cluster1 and cluster2-sno." >&2
  exit 1
}
ACCESS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rhacm-gk-access.XXXXXXXX")"
chmod 700 "$ACCESS_DIR"
trap 'rm -rf -- "$ACCESS_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ocx() {
  local role="$1"; shift
  case "$role" in
    hub) oc --context "$HUB_LOGIN" "$@" ;;
    stage|production) oc --kubeconfig "$ACCESS_DIR/$role" "$@" ;;
    *) echo "ERROR: Unknown cluster role: $role" >&2; return 1 ;;
  esac
}
resolve_access() {
  local cluster="$1" role="$2" ref actual expected
  ocx hub get clusterdeployments.hive.openshift.io -n "$cluster" -o json > "$ACCESS_DIR/deployments.json" || return 1
  ref="$(python3 - "$ACCESS_DIR/deployments.json" "$cluster" <<'PYREF'
import json,sys
items=json.load(open(sys.argv[1]))['items']
matched=[x for x in items if x['metadata']['name']==sys.argv[2] or x.get('spec',{}).get('clusterName')==sys.argv[2]]
if not matched and len(items)==1: matched=items
if len(matched)!=1: raise SystemExit('ERROR: Cannot uniquely identify the ClusterDeployment in '+sys.argv[2])
m=matched[0].get('spec',{}).get('clusterMetadata') or {}
ref=m.get('adminKubeconfigSecretRef',{}).get('name')
if not ref: raise SystemExit('ERROR: ClusterDeployment has no adminKubeconfigSecretRef. Provisioning may be incomplete.')
print(ref)
PYREF
)" || return 1
  # Read only the Secret explicitly referenced by the target ClusterDeployment.
  (umask 077
   ocx hub get secret "$ref" -n "$cluster" -o jsonpath='{.data.kubeconfig}' |
     python3 -c 'import base64,sys; data=sys.stdin.buffer.read().strip(); data or sys.exit("ERROR: Missing kubeconfig data"); sys.stdout.buffer.write(base64.b64decode(data,validate=True))' > "$ACCESS_DIR/$role"
  ) || return 1
  actual="$(ocx "$role" get clusterversion version -o jsonpath='{.spec.clusterID}')" || return 1
  expected="$(python3 - "$ACCESS_DIR/deployments.json" "$ref" <<'PYID'
import json,sys
for x in json.load(open(sys.argv[1]))['items']:
 m=x.get('spec',{}).get('clusterMetadata') or {}
 if m.get('adminKubeconfigSecretRef',{}).get('name')==sys.argv[2]:
  print(m.get('clusterID','')); break
PYID
)"
  if [[ -n "$expected" && "$expected" != "$actual" ]]; then
    echo "ERROR: Kubeconfig cluster identity does not match $cluster." >&2
    return 1
  fi
}
resolve_access cluster2-sno stage || { echo "ERROR: Cannot obtain stage access through its ClusterDeployment. Check hub permissions and provisioning status." >&2; exit 1; }
resolve_access cluster1 production || { echo "ERROR: Cannot obtain production access through its ClusterDeployment. Check hub permissions and provisioning status." >&2; exit 1; }

ocx "$HUB_CONTEXT" get policy ws-gatekeeper-install -n ws-gatekeeper-lab >/dev/null 2>&1 || die "The RHACM installation policy ws-gatekeeper-install is missing. Nothing was cleaned up."

echo "Resetting the namespace exemption while keeping the Gatekeeper installation policy..."
ocx "$HUB_CONTEXT" apply -f "$LAB_DIR/install-gatekeeper.yaml"

for pair in "$STAGE_CONTEXT:stage" "$PROD_CONTEXT:production"; do
  ctx="${pair%%:*}"; label="${pair#*:}"
  exclusion="$(ocx "$ctx" get gatekeeper gatekeeper -o jsonpath='{.spec.config.matches[0].excludedNamespaces[0]}' 2>/dev/null || true)"
  if [[ "$exclusion" == "ws-stage-exempt" ]]; then
    ocx "$ctx" patch gatekeeper gatekeeper --type=json \
      -p='[{"op":"remove","path":"/spec/config/matches/0"}]' >/dev/null
  elif [[ -n "$exclusion" ]]; then
    die "$label: found an unexpected Gatekeeper namespace exclusion '$exclusion'; leaving it untouched."
  fi
done

echo "Removing the RHACM constraint policy..."
ocx "$HUB_CONTEXT" delete policy ws-gatekeeper-container-tags -n ws-gatekeeper-lab --ignore-not-found --wait=false >/dev/null

for pair in "$STAGE_CONTEXT:stage" "$PROD_CONTEXT:production"; do
  ctx="${pair%%:*}"; label="${pair#*:}"
  for _ in $(seq 1 60); do
    template="$(ocx "$ctx" get constrainttemplate wscontainertags -o name 2>/dev/null || true)"
    constraint="$(ocx "$ctx" get wscontainertags ws-no-latest -o name 2>/dev/null || true)"
    [[ -z "$template" && -z "$constraint" ]] && break
    sleep 5
  done
  [[ -z "$(ocx "$ctx" get constrainttemplate wscontainertags -o name 2>/dev/null || true)" ]] || die "$label: ConstraintTemplate remains. Check RHACM policy propagation; test namespaces were left in place."
  [[ -z "$(ocx "$ctx" get wscontainertags ws-no-latest -o name 2>/dev/null || true)" ]] || die "$label: constraint remains. Check RHACM policy propagation; test namespaces were left in place."
done

ocx "$HUB_CONTEXT" delete placementbinding ws-gatekeeper-container-tags -n ws-gatekeeper-lab --ignore-not-found >/dev/null
ocx "$HUB_CONTEXT" delete placement ws-gatekeeper-container-tags -n ws-gatekeeper-lab --ignore-not-found >/dev/null

delete_owned_namespace() {
  local ctx="$1" name="$2" owner
  if ocx "$ctx" get namespace "$name" >/dev/null 2>&1; then
    owner="$(ocx "$ctx" get namespace "$name" -o "go-template={{index .metadata.labels \"$OWNER_LABEL\"}}")"
    [[ "$owner" == "$OWNER_VALUE" ]] || die "Refusing to delete namespace $name: ownership label does not match."
    ocx "$ctx" delete namespace "$name" --wait=false >/dev/null
  fi
}

delete_owned_namespace "$STAGE_CONTEXT" ws-stage
delete_owned_namespace "$STAGE_CONTEXT" ws-stage-exempt
delete_owned_namespace "$PROD_CONTEXT" ws-prod

echo "✅ Exercise constraints and test namespaces removed. Gatekeeper remains installed and managed by ws-gatekeeper-install."
echo "ℹ️ The ws-gatekeeper-lab namespace, its default ManagedClusterSetBinding, and target labels are retained so RHACM keeps Gatekeeper managed on both clusters."
echo "ℹ️ Generated local files remain under $LAB_DIR and contain policies only, not credentials."
