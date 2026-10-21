# Demo: Resource Limits per Project vs. per Deployment

**Goal:** Show the two levels of control and how they work together.

| Level | Object | Answers the question |
|---|---|---|
| **Project** | `ResourceQuota` | How much can the **whole project** use in total? |
| **Project** | `LimitRange` | What are the **default and maximum** values for each container? |
| **Deployment** | `resources.requests/limits` in the Deployment | How much does **this workload** need? |

**File:** `Demo-ResourceLimits.yaml`. In every namespace labeled `org-policy=enforced`, it creates a ResourceQuota and a LimitRange, and **requires** every Deployment to declare its own requests and limits.

---

### Steps

1. Hub console ➔ **+** (Import YAML) ➔ paste `Demo-ResourceLimits.yaml` ➔ **Create**.
2. On cluster1:

   ```bash
   oc new-project demo-limits
   oc label namespace demo-limits org-policy=enforced
   ```

---

### Show It Works (cluster1)

1. **Project level:** cluster1 console ➔ **Administration** ➔ **ResourceQuotas** ➔ project `demo-limits` ➔ `demo-project-quota`. You see the budget and how much is used.

2. **Deployment level:** a Deployment without resources is **rejected**:

   ```bash
   oc create deployment web --image=registry.access.redhat.com/ubi9/httpd-24 -n demo-limits
   ```

   ```text
   ... denied request: Every container must declare CPU and memory requests and limits.
   ```

3. Add resources and it is **allowed**:

   ```bash
   oc create deployment web --image=registry.access.redhat.com/ubi9/httpd-24 -n demo-limits --dry-run=client -o yaml \
     | oc set resources --local -f - --requests=cpu=100m,memory=128Mi --limits=cpu=500m,memory=256Mi -o yaml \
     | oc apply -f -
   ```

4. Back in **ResourceQuotas**: the usage has increased.

---

### Key Points

- **LimitRange** fills in defaults at the **Pod** level. The **Deployment** object itself stays without resources unless the team writes them. That is why the Deployment rule is a separate control.
- The **ResourceQuota** protects the cluster. The **Deployment** limits protect the application, and make capacity planning possible.
- A pod that would exceed the quota is rejected. The Deployment stays at fewer replicas, and the reason is shown in its events.

### Cleanup

`oc delete project demo-limits`, then delete the policy.
