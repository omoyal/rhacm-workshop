# 🛡️ RHACM Governance Demos

Short "how-to" demos. Each demo has a guide (`Demo-<Name>.md`) and a ready-to-apply file (`Demo-<Name>.yaml`).

| # | Demo | What it shows |
|---|---|---|
| 1 | [Policy Generator with GitOps](Demo-PolicyGenerator.md) | Policies generated from plain YAML in Git |
| 2 | [ETCD Encryption](Demo-ETCD-Encryption.md) | Enforce etcd encryption on clusters |
| 3 | [Security Context Constraints](Demo-SCC.md) | Deploy an organizational SCC and prevent drift |
| 4 | [Labels](Demo-Labels.md) | Require labels on Deployments |
| 5 | [Network Policies](Demo-NetworkPolicy.md) | Discover traffic, then enforce baseline Network Policies |
| 6 | [Resource Limits](Demo-ResourceLimits.md) | Limits per Project vs. per Deployment |
| 7 | [Remote Quotas](Demo-RemoteQuotas.md) | A quota shared by several projects, managed from the hub |
| 8 | [Organization-wide Security](Demo-OrgSecurityPolicies.md) | A security baseline as a Policy Set |
| 9 | [Database Encryption](Demo-DatabaseEncryption.md) | Database data only on encrypted storage |
| 10 | [Policy Violations](Demo-PolicyViolations.md) | Find and prevent RBAC / SCC / Labels / NetPol violations |

---

## Before the First Demo (one time)

**1. Create the demo namespace on the hub**

```bash
oc new-project demo-policies
```

**2. Bind the cluster set (Console)**

**Fleet management** ➔ **Infrastructure** ➔ **Clusters** ➔ **Cluster sets** ➔ **default** ➔ **Namespace bindings** (pencil icon) ➔ select `demo-policies` ➔ **Save**.

**3. Clone the repository on the Bastion**

```bash
git clone https://github.com/omoyal/rhacm-workshop.git ~/rhacm-workshop
cd ~/rhacm-workshop/labs/demos
```

---

## How to Apply a Demo File

All demo policies target **cluster1** (cluster label `name=cluster1`).

**Option A (Console):** in the hub console, click **+** (Import YAML) in the top bar, paste the content of `Demo-<Name>.yaml`, and click **Create**.

**Option B (CLI):**

```bash
oc apply -f Demo-<Name>.yaml
```

The policy then appears in **Governance** ➔ **Policies**.

## Working on cluster1

- **Console:** **Infrastructure** ➔ **Clusters** ➔ **cluster1** ➔ **Reveal credentials**, then click the **Console URL** and log in as `kubeadmin`.
- **CLI:** in the cluster1 console, open the user menu (top right) ➔ **Copy login command** ➔ **Display Token**, and run the `oc login` command in a **second** Bastion terminal. Keep the first terminal for the hub.

## Run One Demo at a Time

Several demos act on the same namespaces. After each demo, run its **Cleanup**. Deleting a demo policy also removes what it created on cluster1 (`pruneObjectBehavior: DeleteIfCreated`).

## Namespace Convention

Several demos act only on cluster1 namespaces labeled **`org-policy=enforced`**:

```bash
oc label namespace <name> org-policy=enforced
```
