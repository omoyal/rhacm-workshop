# Demo: Remote Quotas

**Goal:** Define, **from the hub**, one quota shared by **several projects** of the same team on a remote cluster.

**File:** `Demo-RemoteQuotas.yaml`. It creates a **ClusterResourceQuota** on cluster1: all projects labeled `team=demo-team` share **6 pods, 10 services and 5 volumes in total**.

---

### Steps

1. Hub console ➔ **+** (Import YAML) ➔ paste `Demo-RemoteQuotas.yaml` ➔ **Create**.
2. **Governance** ➔ `demo-remote-quotas` ➔ **Results**: `cluster1` is compliant.

---

### Show It Works

1. **From the hub, without logging in to cluster1:** **Fleet management** ➔ **Search** ➔ `kind:ClusterResourceQuota`. The quota appears on `cluster1`. Click it to see its YAML.

2. On cluster1, create two projects for the team:

   ```bash
   oc new-project team-a-dev  && oc label namespace team-a-dev  team=demo-team
   oc new-project team-a-test && oc label namespace team-a-test team=demo-team
   ```

3. Use resources in both, then look at the shared total:

   ```bash
   oc create deployment web --image=registry.access.redhat.com/ubi9/httpd-24 --replicas=4 -n team-a-dev
   oc create deployment web --image=registry.access.redhat.com/ubi9/httpd-24 --replicas=4 -n team-a-test
   oc describe clusterresourcequota demo-team-quota
   ```

   The quota counts pods from **both** projects. Only 6 of the 8 pods are created. The Deployment events show `exceeded quota: demo-team-quota`.

---

### Key Points

- A quota on CPU or memory requires every pod to declare requests (or a LimitRange with defaults). This demo counts objects to keep it simple.
- **ResourceQuota** = one project. **ClusterResourceQuota** = one budget across many projects, selected by label.
- Managed from the hub: change the numbers in the policy, and every selected cluster is updated.
- Inside a project, `oc describe appliedclusterresourcequota` shows the team quota that applies to it.

### Cleanup

`oc delete project team-a-dev team-a-test`, then delete the policy.
