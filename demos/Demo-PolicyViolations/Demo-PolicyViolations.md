# Demo: Identifying and Preventing RBAC / SCC / Labels / NetPol Violations

**Goal:** One policy that **finds** existing violations across the fleet (inform), and **blocks** new ones (enforce).

**File:** `Demo-PolicyViolations.yaml`

| Area | Identify (report) | Prevent (block) |
|---|---|---|
| **RBAC** | `cluster-admin` granted directly to a user | Binding `cluster-admin` inside an application namespace |
| **SCC** | App pods running as `privileged` or `anyuid` | Privileged containers |
| **Labels** | Enforced namespaces and Deployments without `owner` | Deployments without `owner` |
| **NetPol** | Enforced namespaces without a NetworkPolicy | Deleting `default-deny-all` |

"Enforced" = namespaces labeled `org-policy=enforced`.

> 💡 Run this demo **without** the Network Policy demo active. Otherwise the baseline Network Policies are created automatically and there is no NetPol violation to show.

---

### Steps

1. Hub console ➔ **+** (Import YAML) ➔ paste `Demo-PolicyViolations.yaml` ➔ **Create**.
2. On cluster1, create a project that breaks the rules:

   ```bash
   oc new-project demo-violations
   oc label namespace demo-violations org-policy=enforced
   ```

---

### Show It Works

**Identify (Console):**

1. **Governance** ➔ `demo-policy-violations` ➔ **Results**. Each check is a separate row for `cluster1`:
   - `demo-audit-netpol`: `demo-violations` has no NetworkPolicy.
   - `demo-audit-labels`: `demo-violations` has no `owner` label.
   - `demo-audit-rbac` / `demo-audit-scc`: any real findings on the cluster.
2. Click **View details** on a row to see the exact objects.

**Prevent (cluster1 terminal):**

```bash
oc create deployment web --image=registry.access.redhat.com/ubi9/httpd-24 -n demo-violations
```

```text
... denied request: Labels: Deployments must have the label 'owner'.
```

```bash
oc create rolebinding admins --clusterrole=cluster-admin --group=developers -n demo-violations
```

```text
... denied request: RBAC: binding 'cluster-admin' in this namespace is not allowed.
```

**Fix and watch it turn green:**

```bash
oc label namespace demo-violations owner=team-a
oc create -n demo-violations -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes: [Ingress]
YAML
```

Within a minute, `demo-audit-labels` and `demo-audit-netpol` become **compliant**. Now try `oc delete networkpolicy default-deny-all -n demo-violations`: **blocked**.

---

### Key Points

- **Inform** finds what already exists. **Admission rules** stop new problems. Use both.
- Start in inform, fix the findings, then turn on prevention. No surprises for the teams.
- Prevention applies only to enforced namespaces, so the platform itself is never blocked.

### Cleanup

`oc delete project demo-violations`, then delete the policy.
