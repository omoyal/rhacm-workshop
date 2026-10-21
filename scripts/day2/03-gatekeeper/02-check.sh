#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rhacm-gatekeeper-lab"
die() { echo "❌ $*" >&2; exit 1; }
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

need_running_gatekeeper() {
  local ctx="$1" label="$2" cr pods ready
  cr="$(ocx "$ctx" get gatekeeper gatekeeper -o name 2>/dev/null || true)"
  [[ -n "$cr" ]] || die "$label: Gatekeeper CR is not ready yet. Check ws-gatekeeper-install in RHACM Governance."
  pods="$(ocx "$ctx" get pods -n openshift-gatekeeper-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.containerStatuses[*]}{.ready}{" "}{end}{"\n"}{end}' 2>/dev/null || true)"
  [[ -n "$pods" ]] || die "$label: no Gatekeeper pods found in openshift-gatekeeper-system."
  ready="$(awk -F '\t' '$2 == "Running" && $3 !~ /false/ {n++} END {print n+0}' <<< "$pods")"
  (( ready > 0 )) || die "$label: Gatekeeper pods are not Ready yet. Allow installation time, then retry."
  ocx "$ctx" get constrainttemplate wscontainertags -o name >/dev/null 2>&1 || die "$label: ConstraintTemplate wscontainertags is missing. Check ws-gatekeeper-container-tags in RHACM."
  ocx "$ctx" get wscontainertags ws-no-latest -o name >/dev/null 2>&1 || die "$label: constraint ws-no-latest is missing."
  echo "✅ $label: Gatekeeper and the constraint are present."
}

manifest() {
  local namespace="$1" image="$2"
  cat <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gk-check
  namespace: $namespace
spec:
  selector:
    matchLabels: {app: gk-check}
  template:
    metadata:
      labels: {app: gk-check}
    spec:
      containers:
        - name: app
          image: $image
YAML
}

expect_admitted() {
  local ctx="$1" ns="$2" image="$3" label="$4" out
  out="$(mktemp)"
  if manifest "$ns" "$image" | ocx "$ctx" create --dry-run=server -f - >"$out" 2>&1; then
    echo "✅ $label: admitted"
  else
    cat "$out" >&2
    rm -f "$out"
    die "$label: expected admission, but the API server rejected it."
  fi
  rm -f "$out"
}

expect_denied() {
  local ctx="$1" ns="$2" image="$3" label="$4" out
  out="$(mktemp)"
  if manifest "$ns" "$image" | ocx "$ctx" create --dry-run=server -f - >"$out" 2>&1; then
    rm -f "$out"
    die "$label: request was admitted; expected Gatekeeper to deny :latest."
  fi
  if ! grep -Eiq 'denied the request|validation\.gatekeeper\.sh|ws-no-latest|pinned image tag' "$out"; then
    cat "$out" >&2
    rm -f "$out"
    die "$label: request failed, but not with the expected Gatekeeper denial."
  fi
  echo "✅ $label: denied by Gatekeeper"
  rm -f "$out"
}

need_running_gatekeeper "$STAGE_CONTEXT" "Stage"
need_running_gatekeeper "$PROD_CONTEXT" "Production"
expect_denied "$STAGE_CONTEXT" ws-stage example.invalid/training/demo:latest "Stage latest"
expect_admitted "$STAGE_CONTEXT" ws-stage-exempt example.invalid/training/demo:latest "Stage exempt latest"
expect_denied "$PROD_CONTEXT" ws-prod example.invalid/training/demo:latest "Production latest"
expect_admitted "$PROD_CONTEXT" ws-prod example.invalid/training/demo:v1 "Production pinned tag"

echo "🎉 All Gatekeeper lab checks passed. Server-side dry runs created no workloads and pulled no images."
