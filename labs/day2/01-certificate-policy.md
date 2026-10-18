# Lab 1: SSL/TLS Certificate Expiration Enforcement

---

### 🧭 Overview & Context

> **Real-World Impact (The "Why")**
> Kubernetes certificates expire. When an Ingress or Console certificate expires unexpectedly over a weekend, external traffic drops, critical services fail, and emergency troubleshooting begins.
>
> In this lab, we configure a centralized **Inform** policy in RHACM. The policy continuously audits your fleet, flags any certificates due to expire within 300 hours, and reports compliance violations to the dashboard without disrupting active workloads.

---

### Step 1: Clone Repository & Prepare Environment

> **Purpose:** Simulate a real-world incident by generating a temporary TLS certificate with a short 24-hour expiration window and injecting it into the cluster.

1. Open your **Bastion terminal**, clone the workshop repository, and navigate to the lab scripts directory:

   ```bash
   git clone https://github.com/omoyal/rhacm-workshop.git
   cd rhacm-workshop/scripts/day2/01-certificate-policy
   ```

2. Execute the environment preparation script:

   ```bash
   ./01-lab-start.sh
   ```

3. Confirm that the terminal outputs:

   ```text
   ✅ [LAB READY] Environment successfully primed!
   ```

---

### Step 2: Bind the Cluster Set to the Policy Namespace

> **Purpose:** Policies run inside Kubernetes namespaces on the Hub cluster. Before a policy can distribute definitions to managed clusters, its namespace must be granted explicit permission to target cluster sets via a `ManagedClusterSetBinding`.

1. Log in to the **OpenShift Web Console** using **Red Hat Identity Management / Keycloak**.

2. At the top navigation bar, set the perspective switcher to **All Clusters** to open the RHACM Fleet Management view.

3. In the left-hand navigation menu, select **Infrastructure** ➔ **Clusters**.

4. Switch to the **Cluster sets** tab, then select the **default** cluster set.

5. Locate the **Details** card, find **Namespace bindings**, and click the **pencil icon** (Edit).

6. Select `policies-deploy` from the dropdown list, then click **Save**.

---

### Step 3: Create the Certificate Policy

> **Purpose:** Define the desired governance rule: monitor TLS certificates in critical system namespaces with an `Inform` remediation action and `High` severity.

1. In the RHACM left navigation menu, go to **Governance** ➔ **Policies**.

2. Click **Create policy**.

3. Configure **Section 1: Details**:
   - **Name:** `certificate-policy-console-ingress`
   - **Namespace:** `policies-deploy`
   - *Leave the "Disable policy" box unchecked*
   - Click **Next**.

4. Configure **Section 2: Policy templates**:
   - Click **Add policy template** and select **Certificate management expiration**.
   - Set the template name to: `certificate-policy-console-ingress`.
   - In the **Include Namespace** section, delete `default`, then add:
     - `openshift-console`
     - `openshift-ingress`
   - **Remediation action:** Select `Inform`.
   - **Severity:** Select `High`.
   - Click **Next**.

5. Configure **Section 3: Placement**:
   - Select **New Placement** (the name defaults to `certificate-policy-console-ingress-placement`).
   - Under **Cluster sets**, select **default**.
   - Click **Next**, review the configured YAML specifications, then click **Submit**.

---

### Step 4: Investigate the Non-Compliance Alert

> **Purpose:** Observe the RHACM Policy Framework in action. The Klusterlet agent evaluates local TLS certificates against the policy spec and reports violations back to the Hub.

1. On the **Governance** ➔ **Policies** page, click **`certificate-policy-console-ingress`**.

2. Click the **Results** tab.

3. Wait approximately 30 to 60 seconds for the evaluation cycle to complete.

4. Observe the red **Violations** state on `local-cluster`:

   ```text
   1 certificates expire in less than 300h0m0s: openshift-ingress:router-certs
   ```

---

### Step 5: Remediate the Expiring Certificate

> **Purpose:** Simulate remediation by replacing the short-lived secret with a valid 365-day TLS certificate.

1. Return to your **Bastion terminal**.

2. Inspect the non-compliant secret before patching:

   ```bash
   oc get secrets -n openshift-ingress --field-selector type=kubernetes.io/tls
   ```

3. Run the remediation script to update the certificate:

   ```bash
   ./02-remediate-cert.sh
   ```

---

### Step 6: Verify Automatic Fleet Reconciliation

> **Purpose:** Verify that RHACM detects the configuration update and brings the cluster back into compliance automatically without manual triggers.

1. Return to the **Results** tab in the RHACM Console.

2. Within 60 seconds, verify that the cluster status updates to **No violations** (Compliant).

3. Confirm that the message reads:

   ```text
   All evaluated certificates are compliant
   ```

---

### Step 7: Environment Cleanup

> **Purpose:** Clean up resources to maintain an uncluttered environment for subsequent exercises.

1. In your **Bastion terminal**, run the cleanup script:

   ```bash
   ./03-lab-finish.sh
   ```

2. In the RHACM Web Console:
   - Go to **Governance** ➔ **Policies**.
   - Click the actions icon (`⋮`) next to `certificate-policy-console-ingress` and click **Delete**.
   - Ensure the checkboxes for **Associated PlacementBindings** and **Associated Placements or PlacementRules** are checked, then confirm deletion.
