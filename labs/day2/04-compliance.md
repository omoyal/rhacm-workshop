# Lab 4: Deploy and Configure the Compliance Operator by Using RHACM

**⏱️ Time:** ~30 minutes (the operator installation and the scan take a few minutes each)

---

### 🧭 Overview & Context

> **Real-World Impact (The "Why")**
> "Are our clusters secure?" is a question every auditor asks, and "we think so" is not an answer. The **Compliance Operator** scans OpenShift clusters against well-known security benchmarks and reports exactly which checks pass and which fail.
>
> In this lab you deploy the Compliance Operator to all the clusters in the **Asia-Pacific (APAC)** location, run a scan against the **Essential 8 (E8)** standard, and review the compliance report in the RHACM web console, from one place, for the whole fleet.

**Outcomes:**

- Install the Compliance Operator from the RHACM Governance dashboard.
- Deploy the E8 scan policy.
- Check the compliance scan results of the E8 scan.

---

### Before You Begin: Prepare the Environment

1. Open your **Bastion terminal**, update the workshop repository, and navigate to the lab scripts directory:

   ```bash
   cd ~/rhacm-workshop && git pull
   cd scripts/day2/04-compliance
   ```

   > If you don't have the repository yet: `git clone https://github.com/omoyal/rhacm-workshop.git ~/rhacm-workshop`

2. Execute the environment preparation script:

   ```bash
   ./01-lab-start.sh
   ```

3. Confirm that the terminal outputs:

   ```text
   ✅ [LAB READY] Environment successfully primed!
   ```

---

### Step 1: Create the `policies-compliance` Project on the Hub

1. In the **Bastion terminal**, confirm that you are logged in to the **ACM hub**:

   ```bash
   oc whoami --show-server
   ```

2. Create the `policies-compliance` project:

   ```bash
   oc new-project policies-compliance
   ```

   ```text
   Now using project "policies-compliance" on server "https://api.<your-hub>:6443".
   ```

---

### Step 2: Place `cluster1` into a Cluster Set Named `apac`

1. Log in to the **OpenShift Web Console** of your hub using **Keycloak**.

2. At the top navigation bar, set the perspective switcher to **Fleet management**.

3. Select **Infrastructure** ➔ **Clusters**.

4. Click the **Cluster sets** tab, then click **Create cluster set**.

5. Enter `apac` in the **Cluster set name** field and click **Create**. Then click **Manage resource assignments**.

6. Select **cluster1**.

7. Click **Review**. In the confirmation dialog box, click **Save**.

   > 💡 **Instructor Note:** A cluster belongs to **exactly one** cluster set. By assigning `cluster1` to `apac`, you moved it out of the `default` cluster set. The cleanup script returns it at the end of the lab.

8. In the **Details** card of the `apac` cluster set, find **Namespace bindings** and click the **pencil icon** to edit them.

9. Select `policies-compliance` from the **Namespaces** drop-down list, and click **Save**.

   > 📝 **Note:** To use the cluster set within the namespace, a binding must exist from the cluster set to the namespace.

---

### Step 3: Create the Compliance Operator Policy

Create the policy with the following parameters:

| Field name | Value |
|---|---|
| Name | `policy-complianceoperator` |
| Namespace | `policies-compliance` |
| Cluster set | `apac` |
| Remediation | `Inform` |

1. In the left pane, click **Governance**, and click **Create policy**. The **Create policy** page is displayed.

2. Complete the **Details** page with the following values. Leave the **Disable policy** field unchanged.

   | Field name | Value |
   |---|---|
   | Name | `policy-complianceoperator` |
   | Namespace | `policies-compliance` |

3. Click **Next**. On the **Templates** page, select **Inform**. Under the **Policy templates** label, click **Add policy template**, and select **Install the Compliance operator**.

4. Scroll down to **Operator Subscription** and verify that the **Source** field is `redhat-operators`. Click **Next**.

5. On the **Placement** page, click **New placement**.

6. From the **Cluster sets** field, select `apac`. Click **Next**.

7. On the **Policy annotations** page, click **Next**. On the **Review** page, click **Submit**.

   The policy status shows a cluster violation for **cluster1**. The violation indicates that the Compliance Operator is not installed on `cluster1`.

8. In the left pane, click **Governance**, and click the **Policies** tab. The dashboard shows the `policy-complianceoperator` policy. Click the vertical ellipsis icon (`⋮`) to the right of the policy, and click **Enforce**. Click **Enforce** again in the confirmation window to change the policy remediation from `Inform` to `Enforce`.

   Enforce mode installs the Compliance Operator on `cluster1`, and `policy-complianceoperator` changes to **Compliant** status. Click the number of violations to see the details for the cluster update.

9. The violation clears after the Compliance Operator is installed. This takes a few minutes.

   > 💡 **Instructor Note:** This is the "Inform first, then Enforce" pattern: first see what is missing, then let RHACM fix it.

---

### Step 4: Verify the Compliance Operator Installation in the RHACM Web Console

1. In the left pane, click **Search**.

2. Type the following parameters in the search bar to search for the `compliance-operator` subscription:

   | Filter | Value |
   |---|---|
   | `kind` | `subscription` |
   | `name` | `compliance-operator` |

   The search result shows the `compliance-operator` subscription on **cluster1**, in the `openshift-compliance` namespace, from the `redhat-operators` source.

---

### Step 5: Deploy the Essential 8 (E8) Scan Policy to the APAC Location

1. In the **Bastion terminal**, change to the `~/DO0013L/labs/policies-compliance/` directory:

   ```bash
   cd ~/DO0013L/labs/policies-compliance/
   ```

2. Edit the `policy-compliance-operator-e8-scan.yaml` file:
   - In the `policy-e8-scan` policy, set the `spec.remediationAction` field to `enforce`.
   - At the bottom of the file, in the `placement-policy-e8-scan` placement, set the `matchLabels` field to `cluster.open-cluster-management.io/clusterset: apac`.

   ```yaml
   apiVersion: policy.open-cluster-management.io/v1
   kind: Policy
   metadata:
     name: policy-e8-scan
     annotations:
       policy.open-cluster-management.io/standards: NIST SP 800-53
       policy.open-cluster-management.io/categories: CM Configuration Management
       policy.open-cluster-management.io/controls: CM-6 Configuration Settings
   spec:
     remediationAction: enforce
     disabled: false
   ...output omitted...
   kind: Placement
   metadata:
     name: placement-policy-e8-scan
   spec:
     predicates:
       - requiredClusterSelector:
           labelSelector:
             matchLabels:
               cluster.open-cluster-management.io/clusterset: apac
   ```

3. Deploy the E8 scan policy in the `policies-compliance` namespace:

   ```bash
   oc create -f policy-compliance-operator-e8-scan.yaml -n policies-compliance
   ```

   ```text
   policy.policy.open-cluster-management.io/policy-e8-scan created
   placementbinding.policy.open-cluster-management.io/binding-policy-e8-scan created
   placement.cluster.open-cluster-management.io/placement-policy-e8-scan created
   ```

4. Change to the home directory:

   ```bash
   cd ~
   ```

---

### Step 6: Check the Compliance Operator E8 Scan Results

1. In the left pane, click **Governance**. Click the **Policies** tab. In the dashboard, click **policy-e8-scan**. Clusters that violate the policy appear under **Placement**.

2. Click the **Results** tab. The results show three templates for **cluster1**: `compliance-e8-scan`, `compliance-suite-e8`, and `compliance-suite-e8-results`. The `compliance-suite-e8-results` template shows a violation.

   > 📝 **Note:** The scan takes a few minutes. While it runs, `compliance-suite-e8` shows a violation, because the scan is not `DONE` yet. When the scan finishes, it becomes compliant, and `compliance-suite-e8-results` shows the violation.
   >
   > The `compliance-suite-e8-results` template is noncompliant because the policy applies the `mustnothave` condition to `ComplianceCheckResult` objects with the `FAIL` status.

3. Click the **compliance-suite-e8-results** link and review the details. On the details page, you can see the names of the noncompliant objects: each one is an E8 check that failed on `cluster1`.

4. To list the configuration policies, click **Search** in the RHACM web console, type `kind:ConfigurationPolicy`, and press **Enter**.

5. The search results show a list of all the configuration policies.

---

### Check Your Work

1. Run the check script:

   ```bash
   cd ~/rhacm-workshop/scripts/day2/04-compliance
   ./02-check.sh
   ```

2. Review your score. Every ❌ line includes a 👉 hint that points to the step to fix:

   ```text
   ──────────────────────────────────────────────────────────────
   🏆 Score: 100/100  -  Perfect! Your cluster is being scanned for E8 compliance.
   ──────────────────────────────────────────────────────────────
   ```

---

### Finish

Run the cleanup script. This step is important to ensure that resources from this exercise do not impact upcoming exercises.

```bash
cd ~/rhacm-workshop/scripts/day2/04-compliance
./03-lab-finish.sh
```

```text
✅ Environment is clean for the next lab!
```
