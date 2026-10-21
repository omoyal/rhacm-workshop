# 🔐 Gatekeeper with RHACM: block `:latest`

**Time:** 35–45 minutes, plus time for the operator to install.

## Goal

Use RHACM Governance to install Gatekeeper on both managed clusters, then enforce a simple image-tag rule. Compare the same `:latest` deployment in a normal namespace and an exempt namespace.

## Before you start

- The hub and both managed clusters are already available. This lab does not create or import clusters.
- `cluster2-sno` is the stage cluster; `cluster1` is production.
- Gatekeeper is not installed yet. The `redhat-operators` CatalogSource is available on both managed clusters.
- Run from your workshop terminal, already logged in to **your ACM hub** with `oc`.
- Your hub account must be allowed to read the two clusters' `ClusterDeployment` resources and their referenced admin kubeconfig Secrets. `oc` and Python 3 must be installed.
- No context names or additional cluster logins are needed. The scripts discover access through the hub, use private temporary files, and remove those files on exit. Your kubeconfig is unchanged.

> If discovery fails, the script stops with an explanation. It does not guess credentials or install anything on another cluster.

## 1. Prepare the lab

From the repository root, run:

```bash
bash scripts/day2/03-gatekeeper/01-lab-start.sh
```

The script checks access and cluster readiness, binds the existing `default` ManagedClusterSet to a lab namespace, labels the two existing ManagedCluster objects for placement, and creates three clearly labelled test namespaces on their target clusters. It generates the RHACM policies under `~/.cache/rhacm-gatekeeper-lab/`.

Set a short variable for the generated files and a helper for the commands below:

```bash
LAB_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rhacm-gatekeeper-lab"
laboc() { bash scripts/day2/03-gatekeeper/01-lab-start.sh oc "$@"; }
```

## 2. Install Gatekeeper through RHACM

Apply the generated installation policy to the hub:

```bash
laboc hub apply -f "$LAB_DIR/install-gatekeeper.yaml"
```

In **Governance**, find `ws-gatekeeper-install`. Follow its results on both clusters. Installation can take several minutes. Gatekeeper is ready when its CR and pods appear in `openshift-gatekeeper-system` on both clusters.

Ask: what does the Operator install, and what does the `Gatekeeper` custom resource configure?

## 3. Add the image rule

Apply the constraint policy:

```bash
laboc hub apply -f "$LAB_DIR/gatekeeper-constraints.yaml"
```

In Governance, inspect `ws-gatekeeper-container-tags`. On each managed cluster, check that the `ConstraintTemplate` and `WsContainerTags` constraint were created.

## 4. Compare enforcement and an exemption

Try a server-side dry run in the stage namespace. The fake image is never pulled and no Deployment is saved:

```bash
laboc stage create --dry-run=server -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: latest-test
  namespace: ws-stage
spec:
  selector:
    matchLabels: {app: latest-test}
  template:
    metadata:
      labels: {app: latest-test}
    spec:
      containers:
        - name: app
          image: example.invalid/training/demo:latest
EOF
```

Expected: Gatekeeper denies the request. Now update the same RHACM installation policy with the namespace exemption:

```bash
laboc hub apply -f "$LAB_DIR/install-gatekeeper-with-exclusion.yaml"
```

View the Config with `laboc stage get configs.config.gatekeeper.sh config -n openshift-gatekeeper-system -o yaml`. Wait for `ws-stage-exempt` to appear, then repeat the dry run with `namespace: ws-stage-exempt`. Expected: admitted. The exclusion applies to **all Gatekeeper constraints** in that namespace on both selected clusters.

Finally, repeat the `:latest` dry run using `laboc production` and `namespace: ws-prod`. Expected: denied. Change the image tag to `:v1`; expected: admitted.

## 5. Check and clean up

Run the automated checks:

```bash
bash scripts/day2/03-gatekeeper/02-check.sh
```

The check verifies Gatekeeper readiness and tests the deny/allow outcomes using server-side dry runs.

When finished, remove the exercise resources while keeping Gatekeeper installed and managed by RHACM:

```bash
bash scripts/day2/03-gatekeeper/03-lab-finish.sh
```

**Success:** `:latest` is denied in the normal stage and production namespaces, admitted in the exempt namespace, and a pinned `:v1` image is admitted.

> 🧭 If a check fails, inspect the RHACM Policy results first, then the local `ConstraintTemplate` status and Gatekeeper pods. The scripts have been drafted and statically checked; they have not yet been executed in the Showroom environment.
