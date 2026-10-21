# Demo: Enforcing Security Context Constraints (SCC)

**Goal:** Deploy the **organization's SCC** to every cluster, and make sure no one can change it.

**File:** `Demo-SCC.yaml`. It creates the SCC `demo-restricted-org` (no privileged, no root, all capabilities dropped) and a ClusterRole that allows using it.

---

### Steps

1. Hub console ➔ **+** (Import YAML) ➔ paste `Demo-SCC.yaml` ➔ **Create**.
2. **Governance** ➔ `demo-scc` ➔ **Results**: `cluster1` is compliant.

---

### Show It Works

1. On cluster1: `oc get scc demo-restricted-org`. The SCC exists.
2. **Break it on purpose** (cluster1 terminal):

   ```bash
   oc patch scc demo-restricted-org --type merge -p '{"allowPrivilegedContainer":true}'
   ```

3. Wait a few seconds and check again:

   ```bash
   oc get scc demo-restricted-org -o jsonpath='{.allowPrivilegedContainer}{"\n"}'
   ```

   ```text
   false
   ```

   RHACM **reverted** the change. **Governance** ➔ `demo-scc` ➔ **Results** ➔ **View history** shows the drift and the fix.

4. **Grant the SCC** to an application's service account:

   ```bash
   oc create rolebinding use-org-scc --clusterrole=demo-use-restricted-org-scc --serviceaccount=<namespace>:default -n <namespace>
   ```

---

### Key Points

- `enforce` + `musthave`: the SCC is created if missing and repaired if changed.
- Never edit the built-in SCCs (`restricted-v2`, `privileged`, ...). Create your own and grant it with RBAC.
- To **block** privileged workloads, see [Policy Violations](Demo-PolicyViolations.md).

### Cleanup

Delete the policy. RHACM removes the SCC and the ClusterRole it created.
