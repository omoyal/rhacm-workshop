# Demo: Discover Network Traffic and Define Network Policies

**Goal:** First see **who talks to whom**, then lock it down with a baseline that RHACM keeps on every enforced namespace.

**File:** `Demo-NetworkPolicy.yaml`. It creates 3 Network Policies in every namespace labeled `org-policy=enforced`:

| NetworkPolicy | Effect |
|---|---|
| `default-deny-all` | Blocks all incoming traffic |
| `allow-same-namespace` | Pods in the same namespace can talk |
| `allow-from-openshift-ingress` | The router can reach the app (Routes keep working) |

---

### Part 1: Gather Information (cluster1 console)

- **With the Network Observability Operator:** **Observe** ➔ **Network Traffic** ➔ **Topology** tab ➔ filter by namespace. You see the real flows between pods, namespaces and the outside.
- **Without it:** for each namespace, look at:
  - **Networking** ➔ **Services** and **Routes**: what is exposed, and on which ports.
  - **Workloads** ➔ **Pods** ➔ pod **Details**: the labels you will use in `podSelector`.

> 💡 Write down the allowed flows (e.g. *frontend ➔ backend:8080*). Each flow becomes one `ingress` rule.

### Part 2: Define a Policy in the UI (cluster1 console)

**Networking** ➔ **NetworkPolicies** ➔ **Create NetworkPolicy**. The form lets you choose the pod selector, the allowed sources and the ports, without writing YAML.

### Part 3: Enforce a Baseline from RHACM

1. Hub console ➔ **+** (Import YAML) ➔ paste `Demo-NetworkPolicy.yaml` ➔ **Create**.
2. On cluster1, opt in a project:

   ```bash
   oc new-project demo-netpol
   oc label namespace demo-netpol org-policy=enforced
   ```

3. Within a minute:

   ```bash
   oc get networkpolicy -n demo-netpol
   ```

   ```text
   NAME                           POD-SELECTOR   AGE
   allow-from-openshift-ingress   <none>         10s
   allow-same-namespace           <none>         10s
   default-deny-all               <none>         10s
   ```

4. Delete one: `oc delete networkpolicy default-deny-all -n demo-netpol`. RHACM recreates it within seconds.

---

### Key Points

- **Default deny + explicit allow** is the baseline. Application teams then add their own allow rules.
- A new project gets the baseline automatically, as soon as it is labeled.

### Cleanup

`oc delete project demo-netpol`, then delete the policy.
