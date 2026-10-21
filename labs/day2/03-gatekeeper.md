# Lab 3: Enforce Image Tag Rules with Gatekeeper and RHACM

**⏱️ Time:** ~30 minutes

---

### 🧭 Overview & Context

> **Real-World Impact (The "Why")**
> `image: myapp:latest` looks harmless. But `latest` is a moving target: the next time a pod restarts, it can pull different code than the one you tested, with no deployment, no review and no easy rollback. Pinning image tags is a rule most organizations want to **enforce**, not just recommend.
>
> In this lab you use **RHACM Governance** to install the **Gatekeeper** admission controller on `cluster1`, then distribute a Gatekeeper rule that **blocks** any Deployment using the `latest` tag. Every blocked attempt is reported back to the RHACM dashboard.

**How the pieces fit together:**

| Component | Role |
|---|---|
| **RHACM Policy** | Distributes the configuration from the hub to the selected clusters |
| **Gatekeeper** | Checks every request on the cluster and blocks the ones that break the rule |
| **Governance dashboard** | Shows compliance and violations from one place |

---

### Step 1: Prepare the Environment

> **Purpose:** Label `cluster1` as the target of this lab, create the policy namespace on the hub, and generate the lab files.

1. Open your **Bastion terminal**, update the workshop repository, and navigate to the lab scripts directory:

   ```bash
   cd ~/rhacm-workshop && git pull
   cd scripts/day2/03-gatekeeper
   ```

2. Execute the environment preparation script:

   ```bash
   ./01-lab-start.sh
   ```

3. Confirm that the terminal outputs:

   ```text
   ✅ [LAB READY] Environment successfully primed!

      🎯 Target cluster   : cluster1  (label gatekeeper=enabled)
   ```

4. Load the lab helper and move to the lab files directory:

   ```bash
   source ~/lab-work/03-gatekeeper/env.sh
   cd ~/lab-work/03-gatekeeper
   ```

   | Command | Runs against |
   |---|---|
   | `oc` | the **ACM hub** |
   | `oc-prod` | **cluster1** |

   > 💡 Opened a new terminal? Run the `source` command again.

---

### Step 2: Bind the Cluster Set to the Policy Namespace (Console)

> **Purpose:** A policy in the `policy-gatekeeper` namespace can only target clusters from a cluster set that is **bound** to that namespace.

1. Log in to the **OpenShift Web Console** using **Keycloak**.

2. At the top navigation bar, set the perspective switcher to **Fleet management**.

3. Go to **Infrastructure** ➔ **Clusters** and click **cluster1**. In the **Labels** section, find `gatekeeper=enabled`. You will use this label to target the cluster.

4. Go back to **Infrastructure** ➔ **Clusters**, switch to the **Cluster sets** tab, and select the **default** cluster set.

5. Locate the **Details** card, find **Namespace bindings**, and click the **pencil icon** (Edit).

6. Select `policy-gatekeeper` from the dropdown list, then click **Save**.

---

### Step 3: Install Gatekeeper with a Policy (Console)

> **Purpose:** Instead of installing an operator cluster by cluster, describe the desired state once on the hub. RHACM installs it on every selected cluster and keeps it that way.

1. Go to **Governance** ➔ **Policies** and click **Create policy**.

2. Turn the **YAML** toggle on, at the top of the page. Watch the YAML update as you fill in the form.

3. **Details:**
   - **Name:** `policy-gatekeeper-operator`
   - **Namespace:** `policy-gatekeeper`
   - Click **Next**.

4. **Policy templates:**
   - **Remediation:** select **Enforce**.
   - Click **Add policy template** and select **Install Red Hat Gatekeeper Operator policy**.
   - Verify these values, then click **Next**:

   | Field | Value |
   |---|---|
   | Installation Mode | All namespaces on the cluster (default) |
   | Installed Namespace | `openshift-operators` |
   | Subscription Name | `gatekeeper-operator-product` |
   | Channel | `stable` |
   | Source | `redhat-operators` |
   | Source Namespace | `openshift-marketplace` |

5. **Placement:**
   - Click **New placement** and keep the default name.
   - **Cluster sets:** select `default`.
   - Click **Add label expression**:
     - **Label:** `gatekeeper`
     - **Operator:** `equals any of`
     - **Values:** `enabled`
   - Click **Next**.

   > 💡 **Instructor Note:** The placement selects clusters **by label**, not by name. Any cluster you label `gatekeeper=enabled` in the future gets Gatekeeper automatically, with no change to the policy.

6. **Policy annotations:** leave the defaults and click **Next**.

7. **Review:** click **Submit**.

---

### Step 4: Verify the Installation

> **Purpose:** Watch RHACM install the operator and report the result back to the hub.

1. In **Governance** ➔ **Policies**, open **`policy-gatekeeper-operator`** and click the **Results** tab.

2. Wait **3 to 5 minutes**, until all templates for **cluster1** show **No violations**.

3. Confirm from the Bastion that Gatekeeper is running on cluster1:

   ```bash
   oc-prod get pods -n openshift-gatekeeper-system
   ```

   ```text
   NAME                                             READY   STATUS    RESTARTS   AGE
   gatekeeper-audit-xxxxxxxxxx-xxxxx                1/1     Running   0          2m
   gatekeeper-controller-manager-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
   ```

---

### Step 5: Deploy the "No `latest` Tag" Policy

> **Purpose:** Distribute the rule itself. The policy file contains three templates:
> - **ConstraintTemplate:** the rule logic, written in Rego
> - **Constraint:** which resources the rule applies to, and the action (`deny`)
> - **ConfigurationPolicy:** reports every blocked request as a violation in RHACM

1. Look at the rule before you apply it. Find the `rego:` section and the `Placement` at the bottom:

   ```bash
   cat policy-latest.yaml
   ```

2. Create the policy on the hub:

   ```bash
   oc apply -f policy-latest.yaml
   ```

   ```text
   policy.policy.open-cluster-management.io/policy-gatekeeper-containerimage-latest created
   placementbinding.policy.open-cluster-management.io/binding-policy-gatekeeper-containerimage-latest created
   placement.cluster.open-cluster-management.io/placement-policy-gatekeeper-containerimage-latest created
   ```

3. In the console, open **Governance** ➔ **Policies** ➔ **`policy-gatekeeper-containerimage-latest`**. Verify that the **Placement** selects **cluster1**.

4. Confirm that the rule reached cluster1:

   ```bash
   oc-prod get containerimagelatest
   ```

---

### Step 6: Try to Deploy an Image with the `latest` Tag

> **Purpose:** See the rule in action from a developer's point of view.

1. Deploy the `prod-hello` application. Its image uses the `latest` tag:

   ```bash
   oc-prod create -f prod-hello.yaml
   ```

   ```text
   namespace/app-prod created
   service/prod-hello created
   route.route.openshift.io/prod-hello created
   Error from server (Forbidden): error when creating "prod-hello.yaml": admission webhook
   "validation.gatekeeper.sh" denied the request: [containerimagelatest] Deployment/prod-hello:
   container 'prod-hello' is using the latest tag for its image
   (quay.io/redhattraining/hello-world-nginx:latest), which is an anti-pattern.
   ```

   ⛔ The Namespace, Service and Route were created, but the **Deployment was denied**.

2. In the console, open **`policy-gatekeeper-containerimage-latest`** ➔ **Results**. Within a minute, the **`policy-gatekeeper-admission-latest`** template shows **Violations** on cluster1. Click **View details** to see the blocked request.

   > 💡 **Instructor Note:** Gatekeeper blocks the request **on the cluster**. RHACM shows you **from the hub** that someone tried to break the rule, and where.

---

### Step 7: Fix the Application and Deploy Again

1. Pin the image to the `v1.0` tag:

   ```bash
   sed -i 's/hello-world-nginx:latest/hello-world-nginx:v1.0/' prod-hello.yaml
   grep image: prod-hello.yaml
   ```

   ```text
             image: quay.io/redhattraining/hello-world-nginx:v1.0
   ```

2. Delete the resources left over from the failed attempt. You can ignore the `NotFound` error for the Deployment:

   ```bash
   oc-prod delete -f prod-hello.yaml
   ```

3. Create the application again. This time Gatekeeper **allows** it:

   ```bash
   oc-prod create -f prod-hello.yaml
   ```

   ```text
   namespace/app-prod created
   deployment.apps/prod-hello created
   service/prod-hello created
   route.route.openshift.io/prod-hello created
   ```

   > ⚠️ If you get `namespaces "app-prod" already exists`, the namespace is still being deleted. Wait a few seconds and run the command again.

4. Test the application:

   ```bash
   oc-prod rollout status deployment/prod-hello -n app-prod
   curl -s -o /dev/null -w '%{http_code}\n' "http://$(oc-prod get route prod-hello -n app-prod -o jsonpath='{.spec.host}')"
   ```

   ```text
   200
   ```

---

### Step 8: Check Your Work

1. Run the check script:

   ```bash
   cd ~/rhacm-workshop/scripts/day2/03-gatekeeper
   ./02-check.sh
   ```

2. Review your score. Every ❌ line includes a 👉 hint that points to the step to fix:

   ```text
   ──────────────────────────────────────────────────────────────
   🏆 Score: 100/100  -  Perfect! Gatekeeper is enforcing your policy.
   ──────────────────────────────────────────────────────────────
   ```

---

### Step 9: Environment Cleanup

1. **Delete the policies from the RHACM Console first:**
   - Navigate to **Governance** ➔ **Policies**.
   - For **each** of `policy-gatekeeper-operator` and `policy-gatekeeper-containerimage-latest`:
     - Click the actions menu (`⋮`) on the right and select **Delete**.
     - **Important:** Ensure both checkboxes are selected:
       - ☑ **Associated PlacementBindings**
       - ☑ **Associated Placements or PlacementRules**
     - Click **Delete**.

2. **Clean up the remaining resources via the Bastion Terminal:**

   ```bash
   cd ~/rhacm-workshop/scripts/day2/03-gatekeeper
   ./03-lab-finish.sh
   ```

   ```text
   ✅ Environment is clean for the next lab!
   ```

   > 💡 **Instructor Note:** Deleting a policy does **not** uninstall what it installed. RHACM will not remove an operator just because a policy was deleted. The cleanup script removes Gatekeeper explicitly.

---

### 🎯 What You Achieved

- ✅ Installed an operator through an RHACM policy, targeting clusters by **label**.
- ✅ Enforced an organizational rule at **admission time** with Gatekeeper.
- ✅ Saw blocked requests reported as **violations** in the Governance dashboard.

> 🧩 The same pattern also enforces **mandatory labels**, **resource limits**, **SCC usage** and **NetworkPolicies** across the fleet. Only the rule changes.
