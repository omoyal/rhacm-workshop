# Lab 3: Enforce Image Tag Rules with Gatekeeper and RHACM

**⏱️ Time:** ~20 minutes

---

### 🧭 Overview & Context

> **Real-World Impact (The "Why")**
> `image: myapp:latest` is a moving target: the next time a pod restarts, it can pull different code than the one you tested. Pinning image tags is a rule most organizations want to **enforce**, not just recommend.
>
> In this lab you use **RHACM Governance** to install **Gatekeeper** on `cluster1`, then distribute a rule that **blocks** any Deployment using the `latest` tag. Every blocked attempt is reported back to the RHACM dashboard.

---

### Step 1: Clone Repository & Prepare Environment

1. Open your **Bastion terminal**, clone the workshop repository, and navigate to the lab scripts directory:

   ```bash
   git clone https://github.com/omoyal/rhacm-workshop.git ~/rhacm-workshop
   cd ~/rhacm-workshop/scripts/day2/03-gatekeeper
   ```

2. Execute the environment preparation script:

   ```bash
   ./01-lab-start.sh
   ```

3. Confirm that the terminal outputs:

   ```text
   ✅ [LAB READY] Environment successfully primed!
   ```

4. Load the lab helper and move to the lab files directory:

   ```bash
   source ~/lab-work/03-gatekeeper/env.sh
   cd ~/lab-work/03-gatekeeper
   ```

   > 💡 From now on, `oc` runs against the **ACM hub** and `oc-prod` runs against **cluster1**.

---

### Step 2: Bind the Cluster Set to the Policy Namespace

> **Purpose:** A policy in the `policy-gatekeeper` namespace can only target clusters from a cluster set that is **bound** to that namespace.

1. Log in to the **OpenShift Web Console** of your hub using **Keycloak**, and set the perspective switcher to **Fleet management**.

2. Go to **Infrastructure** ➔ **Clusters** ➔ **Cluster sets** tab, and select the **default** cluster set.

3. In the **Details** card, find **Namespace bindings** and click the **pencil icon** (Edit).

4. Select `policy-gatekeeper`, then click **Save**.

---

### Step 3: Install Gatekeeper with a Policy

> **Purpose:** Describe the desired state once on the hub. RHACM installs the operator on every selected cluster and keeps it that way.

1. Go to **Governance** ➔ **Policies** and click **Create policy**.

2. **Details:**
   - **Name:** `policy-gatekeeper-operator`
   - **Namespace:** `policy-gatekeeper`
   - Click **Next**.

3. **Policy templates:**
   - **Remediation:** select **Enforce**.
   - Click **Add policy template** and select **Install Red Hat Gatekeeper Operator policy**.
   - Keep the default values (Channel `stable`, Source `redhat-operators`) and click **Next**.

4. **Placement:**
   - Click **New placement** and keep the default name.
   - **Cluster sets:** select `default`.
   - Click **Add label expression**: **Label** `gatekeeper`, **Operator** `equals any of`, **Values** `enabled`.
   - Click **Next**.

   > 💡 **Instructor Note:** The placement selects clusters **by label**, not by name. The start script labeled `cluster1` with `gatekeeper=enabled`, so only `cluster1` is selected.

5. **Policy annotations:** click **Next**. **Review:** click **Submit**.

---

### Step 4: Verify the Installation on cluster1

> **Purpose:** Log in to the console of the managed cluster and see what RHACM installed there.

1. In **Governance** ➔ **Policies** ➔ **`policy-gatekeeper-operator`**, open the **Results** tab. Wait **3 to 5 minutes** until all rows for `cluster1` show **No violations**.

2. Open the console of **cluster1**:
   - Go to **Infrastructure** ➔ **Clusters** and click **cluster1**.
   - In the **Details** card, click **Reveal credentials** and copy the `kubeadmin` password.
   - Click the **Console URL** link. The cluster1 console opens in a new tab.
   - Log in with the username `kubeadmin` and the password you copied. If you are asked to choose a login method, select **kube:admin**.

3. In the **cluster1** console, go to **Operators** ➔ **Installed Operators** and select **All Projects**. Verify that **Gatekeeper Operator** appears with status **Succeeded**.

   > 💡 Keep this tab open. You will use it again in the next step.

---

### Step 5: Deploy the "No `latest` Tag" Policy

> **Purpose:** Distribute the rule itself. The file contains a Gatekeeper **ConstraintTemplate** (the rule logic), a **Constraint** (the action: `deny`), and a **ConfigurationPolicy** that reports blocked requests to RHACM.

1. In the **Bastion terminal**, create the policy on the hub:

   ```bash
   oc apply -f policy-latest.yaml
   ```

   ```text
   policy.policy.open-cluster-management.io/policy-gatekeeper-containerimage-latest created
   placementbinding.policy.open-cluster-management.io/binding-policy-gatekeeper-containerimage-latest created
   placement.cluster.open-cluster-management.io/placement-policy-gatekeeper-containerimage-latest created
   ```

2. In the **hub** console, go to **Governance** ➔ **Policies** and verify that **`policy-gatekeeper-containerimage-latest`** appears, with **cluster1** as its target.

3. In the **cluster1** console tab, go to **Administration** ➔ **CustomResourceDefinitions** and search for `ContainerImageLatest`. Open it and click the **Instances** tab. The `containerimagelatest` rule now exists on cluster1.

---

### Step 6: Test the Rule on cluster1

> **Purpose:** Deploy an application to **cluster1** from the Bastion (with `oc-prod`) and see the rule in action.

1. Deploy the `prod-hello` application to **cluster1**. Its image uses the `latest` tag:

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

   ⛔ Gatekeeper on cluster1 **denied the Deployment**. The other resources were created.

2. In the **hub** console, open **`policy-gatekeeper-containerimage-latest`** ➔ **Results**. Within a minute, cluster1 shows **Violations**.

3. Fix the application by pinning the image to the `v1.0` tag, remove the leftovers, and deploy it again to **cluster1**:

   ```bash
   sed -i 's/hello-world-nginx:latest/hello-world-nginx:v1.0/' prod-hello.yaml
   oc-prod delete -f prod-hello.yaml
   oc-prod create -f prod-hello.yaml
   ```

   ```text
   namespace/app-prod created
   deployment.apps/prod-hello created
   service/prod-hello created
   route.route.openshift.io/prod-hello created
   ```

   ✅ This time Gatekeeper **allowed** the Deployment.

   > ⚠️ If you get `namespaces "app-prod" already exists`, the namespace is still being deleted. Wait a few seconds and run `oc-prod create -f prod-hello.yaml` again.

4. In the **cluster1** console tab, go to **Workloads** ➔ **Deployments**, select the project **app-prod**, and verify that `prod-hello` has **1 of 1 pods** running.

---

### Step 7: Check Your Work

```bash
cd ~/rhacm-workshop/scripts/day2/03-gatekeeper
./02-check.sh
```

```text
🏆 Score: 100/100  -  Perfect! Gatekeeper is enforcing your policy.
```

Every ❌ line includes a 👉 hint that points to the step to fix.

---

### Step 8: Environment Cleanup

1. **Delete the policies from the hub console first:**
   - Navigate to **Governance** ➔ **Policies**.
   - For **each** of `policy-gatekeeper-operator` and `policy-gatekeeper-containerimage-latest`:
     - Click the actions menu (`⋮`) and select **Delete**.
     - Ensure both checkboxes are selected: ☑ **Associated PlacementBindings** and ☑ **Associated Placements or PlacementRules**.
     - Click **Delete**.

2. **Clean up the remaining resources from the Bastion terminal:**

   ```bash
   ./03-lab-finish.sh
   ```

   ```text
   ✅ Environment is clean for the next lab!
   ```

   > 💡 **Instructor Note:** Deleting a policy does **not** uninstall what it installed. The cleanup script removes Gatekeeper from cluster1.
