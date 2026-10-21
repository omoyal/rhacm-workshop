# Demo: Enforcing Organization-wide Security Policies

**Goal:** Group the organization's security rules into one **Policy Set**: one name, one placement, one compliance status for the whole baseline.

**File:** `Demo-OrgSecurityPolicies.yaml`. It creates two policies and the Policy Set `demo-org-security-baseline`:

| Policy | Checks |
|---|---|
| `demo-no-kubeadmin` | The temporary `kubeadmin` user was removed |
| `demo-no-public-cluster-admin` | No one gave `cluster-admin` to **all** authenticated users |

---

### Steps

1. Hub console ➔ **+** (Import YAML) ➔ paste `Demo-OrgSecurityPolicies.yaml` ➔ **Create**.
2. **Governance** ➔ **Policy sets** tab ➔ **`demo-org-security-baseline`**.

---

### Show It Works

1. The Policy Set card shows **one** status for the whole baseline. `cluster1` is **non-compliant**, because the `kubeadmin` user still exists on it.
2. Click the set ➔ see which policy failed and on which cluster.
3. **Add another rule in the UI:** on the set, click **⋮** ➔ **Edit** ➔ add an existing policy (for example `demo-etcd-encryption` or `demo-scc`) ➔ **Submit**. The baseline now includes it.

---

### Key Points

- These two policies are **inform**: they report and do not change anything. Removing `kubeadmin` is a decision for the cluster owner, after another admin login is in place.
- A Policy Set is how you present a **standard** ("the security baseline") to management and auditors.
- For a full benchmark (CIS, NIST), install the **Compliance Operator** with a policy and add its results to the same governance view.

### Cleanup

Delete the Policy Set, `demo-no-kubeadmin` and `demo-no-public-cluster-admin`.
