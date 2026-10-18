# Lab 1: SSL/TLS Certificate Expiration Enforcement

---

### 🧭 Overview & Context

> **Real-World Impact (The "Why")**
> Kubernetes certificates expire. When an Ingress or Console certificate expires unexpectedly over a weekend, external traffic drops, critical services fail, and emergency troubleshooting begins[cite: 13].
>
> In this lab, we configure a centralized **Inform** policy in RHACM[cite: 13, 16]. The policy continuously audits your fleet, flags any certificates due to expire within 300 hours, and reports compliance violations to the dashboard without disrupting active workloads[cite: 13, 16, 17].

---

### Step 1: Clone Repository & Prepare Environment

> **Purpose:** Simulate a real-world incident by generating a temporary TLS certificate with a short 24-hour expiration window and injecting it into the cluster[cite: 17].

1. Open your **Bastion terminal**, clone the workshop repository, and navigate to the lab scripts directory:

   ```bash
   git clone [https://github.com/omoyal/rhacm-workshop.git](https://github.com/omoyal/rhacm-workshop.git)
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

> **Purpose:** Policies run inside Kubernetes namespaces on the Hub cluster[cite: 1, 13]. Before a policy can distribute definitions to managed clusters, its namespace must be granted explicit permission to target cluster sets via a `ManagedClusterSetBinding`[cite: 1, 13].

1. Log in to the **OpenShift Web Console** using **Red Hat Identity Management / Keycloak**[cite: 13].

2. At the top navigation bar, set the perspective switcher to **All Clusters** to open the RHACM Fleet Management view[cite: 13].

3. In the left-hand navigation menu, select **Infrastructure** ➔ **Clusters**[cite: 13].

4. Switch to the **Cluster sets** tab, then select the **default** cluster set[cite: 13].

5. Locate the **Details** card, find **Namespace bindings**, and click the **pencil icon** (Edit)[cite: 14].

6. Select `policies-deploy` from the dropdown list, then click **Save**[cite: 13, 14].

---

### Step 3: Create the Certificate Policy

> **Purpose:** Define the desired governance rule: monitor TLS certificates in critical system namespaces with an `Inform` remediation action and `High` severity[cite: 15, 16].

1. In the RHACM left navigation menu, go to **Governance** ➔ **Policies**[cite: 14].

2. Click **Create policy**[cite: 14].

3. Configure **Section 1: Details**:
   - **Name:** `certificate-policy-console-ingress`[cite: 15]
   - **Namespace:** `policies-deploy`[cite: 15]
   - *Leave the "Disable policy" box unchecked*[cite: 15]
   - Click **Next**[cite: 15].

4. Configure **Section 2: Policy templates**:
   - Click **Add policy template** and select **Certificate management expiration**[cite: 15].
   - Set the template name to: `certificate-policy-console-ingress`[cite: 15].
   - In the **Include Namespace** section, delete `default`, then add:
     - `openshift-console`[cite: 15]
     - `openshift-ingress`[cite: 15]
   - **Remediation action:** Select `Inform`[cite: 16].
   - **Severity:** Select `High`[cite: 16].
   - Click **Next**[cite: 16].

5. Configure **Section 3: Placement**:
   - Select **New Placement** (the name defaults to `certificate-policy-console-ingress-placement`)[cite: 16].
   - Under **Cluster sets**, select **default**[cite: 16].
   - Click **Next**, review the configured YAML specifications, then click **Submit**[cite: 16].

---

### Step 4: Investigate the Non-Compliance Alert

> **Purpose:** Observe the RHACM Policy Framework in action. The Klusterlet agent evaluates local TLS certificates against the policy spec and reports violations back to the Hub[cite: 1, 16, 17].

1. On the **Governance** ➔ **Policies** page, click **`certificate-policy-console-ingress`**[cite: 16].

2. Click the **Results** tab[cite: 16].

3. Wait approximately 30 to 60 seconds for the evaluation cycle to complete[cite: 17].

4. Observe the red **Violations** state on `local-cluster`[cite: 17]:

   ```text
   1 certificates expire in less than 300h0m0s: openshift-ingress:router-certs
   ```

---

### Step 5: Remediate the Expiring Certificate

> **Purpose:** Simulate remediation by replacing the short-lived secret with a valid 365-day TLS certificate[cite: 17].

1. Return to your **Bastion terminal**[cite: 17].

2. Inspect the non-compliant secret before patching[cite: 17]:

   ```bash
   oc get secrets -n openshift-ingress --field-selector type=kubernetes.io/tls
   ```

3. Run the remediation script to update the certificate[cite: 17]:

   ```bash
   ./02-remediate-cert.sh
   ```

---

### Step 6: Verify Automatic Fleet Reconciliation

> **Purpose:** Verify that RHACM detects the configuration update and brings the cluster back into compliance automatically without manual triggers[cite: 17, 18].

1. Return to the **Results** tab in the RHACM Console[cite: 17, 18].

2. Within 60 seconds, verify that the cluster status updates to **No violations** (Compliant)[cite: 18].

3. Confirm that the message reads:

   ```text
   All evaluated certificates are compliant
   ```

---

### Step 7: Environment Cleanup

> **Purpose:** Clean up resources to maintain an uncluttered environment for subsequent exercises[cite: 11, 18, 19].

1. In your **Bastion terminal**, run the cleanup script[cite: 19]:

   ```bash
   ./03-lab-finish.sh
   ```

2. In the RHACM Web Console:
   - Go to **Governance** ➔ **Policies**[cite: 18].
   - Click the actions icon (`⋮`) next to `certificate-policy-console-ingress` and click **Delete**[cite: 18].
   - Ensure the checkboxes for **Associated PlacementBindings** and **Associated Placements or PlacementRules** are checked, then confirm deletion[cite: 18].
