# Demo: Policy Generator with GitOps

**Goal:** Write plain Kubernetes YAML in Git. RHACM turns it into policies automatically, and every commit updates the fleet.

**Files:** `Demo-PolicyGenerator/` (`kustomization.yaml`, `Demo-PolicyGenerator.yaml`, `Demo-PolicyGenerator-namespace.yaml`)

---

### How It Works

| File | Role |
|---|---|
| `Demo-PolicyGenerator-namespace.yaml` | A plain manifest: what we want on the clusters |
| `Demo-PolicyGenerator.yaml` | The generator: policy name, namespace, placement (`cluster1`), `enforce` |
| `kustomization.yaml` | Tells Kustomize to run the generator |

---

### Steps (Console)

1. Hub console ➔ **Fleet management** ➔ **Applications** ➔ **Create application** ➔ **Subscription**.

2. Fill in:

   | Field | Value |
   |---|---|
   | Name | `demo-policy-generator` |
   | Namespace | `demo-policies` |
   | Repository type | **Git** |
   | URL | `https://github.com/omoyal/rhacm-workshop.git` |
   | Branch | `main` |
   | Path | `labs/demos/Demo-PolicyGenerator` |

3. **Select clusters for application deployment:** **Deploy application resources on clusters with all specified labels** ➔ label `local-cluster` = `true`.

   > 💡 The **policies** are deployed to the **hub**. RHACM then distributes them to `cluster1`.

4. Click **Create**.

---

### Show It Works

1. **Governance** ➔ **Policies**: the policy **`demo-gitops-namespace`** appears. It was generated, not written by hand.
2. Open it ➔ **Results**: `cluster1` is **compliant**.
3. On cluster1: **Home** ➔ **Projects** ➔ `demo-gitops` exists, with the label `owner=platform-team`.
4. **GitOps in action:** change the `owner` label in `Demo-PolicyGenerator-namespace.yaml`, commit and push. Within a few minutes the label is updated on cluster1.

---

### Key Points

- No Policy YAML is written by hand: the generator adds the Policy, Placement and PlacementBinding.
- Git is the single source of truth: review, history and rollback come from Git.
- The Policy Generator is built into RHACM Git subscriptions. To use **Argo CD (OpenShift GitOps)** instead, Argo CD needs the Policy Generator plugin (`kustomizeBuildOptions: --enable-alpha-plugins`).

### Cleanup

**Applications** ➔ `demo-policy-generator` ➔ **Delete**. The generated policy is removed, and RHACM deletes `demo-gitops` from cluster1.
