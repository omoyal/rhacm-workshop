#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rhacm-gatekeeper-lab"
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

# Optional command mode used by the participant guide; skips lab preparation.
if [[ "${1:-}" == "oc" ]]; then
  shift
  [[ $# -ge 2 ]] || { echo "Usage: $0 oc hub|stage|production <oc arguments>" >&2; exit 1; }
  ocx "$@"
  exit
fi
STAGE_CLUSTER=cluster2-sno
PROD_CLUSTER=cluster1
OWNER_LABEL=workshop.rhacm.io/owner
OWNER_VALUE=gatekeeper-lab
TARGET_LABEL=workshop.rhacm.io/gatekeeper-target
die() { echo "ERROR: $*" >&2; exit 1; }

echo "Checking hub and managed clusters..."
ocx "$HUB_CONTEXT" get managedcluster "$STAGE_CLUSTER" -o name >/dev/null || die "Cannot find ManagedCluster $STAGE_CLUSTER on the hub."
ocx "$HUB_CONTEXT" get managedcluster "$PROD_CLUSTER" -o name >/dev/null || die "Cannot find ManagedCluster $PROD_CLUSTER on the hub."
for cluster in "$STAGE_CLUSTER" "$PROD_CLUSTER"; do
  available="$(ocx "$HUB_CONTEXT" get managedcluster "$cluster" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}')"
  [[ "$available" == "True" ]] || die "ManagedCluster $cluster is not Available. Check RHACM before continuing."
done

for pair in "$STAGE_CONTEXT:$STAGE_CLUSTER" "$PROD_CONTEXT:$PROD_CLUSTER"; do
  ctx="${pair%%:*}"; cluster="${pair#*:}"
  ocx "$ctx" get clusterversion version -o name >/dev/null || die "Context '$ctx' cannot read the OpenShift cluster version."
  ocx "$ctx" get catalogsource redhat-operators -n openshift-marketplace -o name >/dev/null || die "CatalogSource redhat-operators is missing on $cluster."
done

ensure_namespace() {
  local ctx="$1" name="$2" owner
  if ocx "$ctx" get namespace "$name" >/dev/null 2>&1; then
    owner="$(ocx "$ctx" get namespace "$name" -o "go-template={{index .metadata.labels \"$OWNER_LABEL\"}}")"
    [[ "$owner" == "$OWNER_VALUE" ]] || die "Namespace $name already exists and is not owned by this lab. Remove the conflict manually or choose another name."
  else
    ocx "$ctx" create namespace "$name" >/dev/null
    ocx "$ctx" label namespace "$name" "$OWNER_LABEL=$OWNER_VALUE" >/dev/null
  fi
}

ensure_namespace "$HUB_CONTEXT" ws-gatekeeper-lab
ensure_namespace "$STAGE_CONTEXT" ws-stage
ensure_namespace "$STAGE_CONTEXT" ws-stage-exempt
ensure_namespace "$PROD_CONTEXT" ws-prod

for cluster in "$STAGE_CLUSTER" "$PROD_CLUSTER"; do
  current="$(ocx "$HUB_CONTEXT" get managedcluster "$cluster" -o "go-template={{with index .metadata.labels \"$TARGET_LABEL\"}}{{.}}{{end}}")"
  [[ -z "$current" || "$current" == "true" ]] || die "ManagedCluster $cluster already has $TARGET_LABEL=$current. Resolve this label before continuing."
  if [[ -z "$current" ]]; then
    ocx "$HUB_CONTEXT" label managedcluster "$cluster" "$TARGET_LABEL=true" >/dev/null
  fi
done

ocx "$HUB_CONTEXT" apply -f - >/dev/null <<'YAML'
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: default
  namespace: ws-gatekeeper-lab
spec:
  clusterSet: default
YAML

mkdir -p "$LAB_DIR"
# Non-secret files only. Access credentials live in ACCESS_DIR and are removed on exit.
rm -f "$LAB_DIR/hub-context" "$LAB_DIR/stage-context" "$LAB_DIR/prod-context"

cat > "$LAB_DIR/install-gatekeeper.yaml" <<'YAML'
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: ws-gatekeeper-install
  namespace: ws-gatekeeper-lab
spec:
  remediationAction: enforce
  disabled: false
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1beta1
        kind: OperatorPolicy
        metadata:
          name: ws-gatekeeper-operator
        spec:
          remediationAction: enforce
          complianceType: musthave
          severity: medium
          upgradeApproval: Automatic
          subscription:
            namespace: openshift-operators
            name: gatekeeper-operator-product
            channel: stable
            source: redhat-operators
            sourceNamespace: openshift-marketplace
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: ws-gatekeeper-instance
        spec:
          remediationAction: enforce
          severity: medium
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: operator.gatekeeper.sh/v1alpha1
                kind: Gatekeeper
                metadata:
                  name: gatekeeper
                spec:
                  validatingWebhook: Enabled
                  mutatingWebhook: Disabled
                  config:
                    disableDefaultMatches: false
                    matches: []
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: ws-gatekeeper-install
  namespace: ws-gatekeeper-lab
placementRef:
  name: ws-gatekeeper-install
  kind: Placement
  apiGroup: cluster.open-cluster-management.io
subjects:
  - name: ws-gatekeeper-install
    kind: Policy
    apiGroup: policy.open-cluster-management.io
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: ws-gatekeeper-install
  namespace: ws-gatekeeper-lab
spec:
  clusterSets:
    - default
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchLabels:
            workshop.rhacm.io/gatekeeper-target: "true"
YAML

cp "$LAB_DIR/install-gatekeeper.yaml" "$LAB_DIR/install-gatekeeper-with-exclusion.yaml"
python3 - "$LAB_DIR/install-gatekeeper-with-exclusion.yaml" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace('                    matches: []', '''                    matches:
                      - excludedNamespaces:
                          - ws-stage-exempt
                        processes:
                          - "*"''')
if s == p.read_text():
    raise SystemExit("Could not generate the Gatekeeper exclusion policy")
p.write_text(s)
PY

cat > "$LAB_DIR/gatekeeper-constraints.yaml" <<'YAML'
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: ws-gatekeeper-container-tags
  namespace: ws-gatekeeper-lab
spec:
  remediationAction: enforce
  disabled: false
  policy-templates:
    - objectDefinition:
        apiVersion: templates.gatekeeper.sh/v1beta1
        kind: ConstraintTemplate
        metadata:
          name: wscontainertags
        spec:
          crd:
            spec:
              names:
                kind: WsContainerTags
              validation:
                openAPIV3Schema:
                  type: object
          targets:
            - target: admission.k8s.gatekeeper.sh
              rego: |
                package wscontainertags

                violation[{"msg": msg}] {
                  input.review.kind.kind == "Deployment"
                  container := input.review.object.spec.template.spec.containers[_]
                  endswith(container.image, ":latest")
                  msg := sprintf("container %q must use a pinned image tag instead of :latest", [container.name])
                }

                violation[{"msg": msg}] {
                  input.review.kind.kind == "Pod"
                  container := input.review.object.spec.containers[_]
                  endswith(container.image, ":latest")
                  msg := sprintf("container %q must use a pinned image tag instead of :latest", [container.name])
                }
    - objectDefinition:
        apiVersion: constraints.gatekeeper.sh/v1beta1
        kind: WsContainerTags
        metadata:
          name: ws-no-latest
        spec:
          enforcementAction: deny
          match:
            kinds:
              - apiGroups: [""]
                kinds: [Pod]
              - apiGroups: [apps]
                kinds: [Deployment]
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: ws-gatekeeper-container-tags
  namespace: ws-gatekeeper-lab
placementRef:
  name: ws-gatekeeper-container-tags
  kind: Placement
  apiGroup: cluster.open-cluster-management.io
subjects:
  - name: ws-gatekeeper-container-tags
    kind: Policy
    apiGroup: policy.open-cluster-management.io
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: ws-gatekeeper-container-tags
  namespace: ws-gatekeeper-lab
spec:
  clusterSets:
    - default
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchLabels:
            workshop.rhacm.io/gatekeeper-target: "true"
YAML

echo "✅ Lab prepared. Generated policies: $LAB_DIR"
echo "Next: inspect and apply install-gatekeeper.yaml from the lab guide."
