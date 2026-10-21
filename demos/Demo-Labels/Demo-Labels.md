# Demo: Enforcing Labels Usage and Best Practices

**Goal:** Every Deployment must have the labels `app.kubernetes.io/name` and `owner`. Deployments without them are **rejected**.

**File:** `Demo-Labels.yaml`. RHACM distributes a **ValidatingAdmissionPolicy**, the built-in admission control of Kubernetes. No extra operator is needed.

---

### Steps

1. Hub console ➔ **+** (Import YAML) ➔ paste `Demo-Labels.yaml` ➔ **Create**.
2. **Governance** ➔ `demo-labels` ➔ **Results**: `cluster1` is compliant.

---

### Show It Works (cluster1)

1. Create a test project and opt it in to the rule:

   ```bash
   oc new-project demo-labels
   oc label namespace demo-labels org-policy=enforced
   ```

2. Without labels: **rejected**:

   ```bash
   oc create deployment web --image=registry.access.redhat.com/ubi9/httpd-24 -n demo-labels
   ```

   ```text
   error: failed to create deployment: deployments.apps "web" is forbidden: ValidatingAdmissionPolicy
   'demo-required-labels' with binding 'demo-required-labels' denied request: Deployments must have
   the labels 'app.kubernetes.io/name' and 'owner'.
   ```

3. With labels: **allowed**. In the cluster1 console, select project `demo-labels` ➔ **+** (Import YAML) ➔ paste:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: demo-labels
     labels:
       app.kubernetes.io/name: web
       owner: team-a
   spec:
     selector:
       matchLabels:
         app.kubernetes.io/name: web
     template:
       metadata:
         labels:
           app.kubernetes.io/name: web
       spec:
         containers:
           - name: web
             image: registry.access.redhat.com/ubi9/httpd-24
   ```

---

### Key Points

- **Best practice labels:** `app.kubernetes.io/name` (what), `owner` (who to call). Add `cost-center` and `environment` the same way.
- The rule applies only to namespaces labeled `org-policy=enforced`, so platform namespaces are never affected. Roll it out project by project.
- Requires OpenShift 4.17 or later.

### Cleanup

`oc delete project demo-labels`, then delete the policy.
