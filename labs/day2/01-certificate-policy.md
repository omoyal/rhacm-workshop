# Lab 1: SSL/TLS Certificate Expiration Enforcement (Day 2)

### Real-World Scenario (The "Why")
Kubernetes certificates expire. When an Ingress or Console certificate expires over the weekend, services crash and troubleshooting begins. 
In this lab, we will configure a central **Inform** policy in RHACM that scans all clusters, identifies certificates expiring in less than 300 hours, and reports a violation to the dashboard.

---

### Step 1: Clone Repo & Prepare Environment (Bastion Terminal)
> **Why?** We are simulating a production issue: We will generate a dummy TLS certificate with a short lifespan of 24 hours and inject it into the cluster.

1. In your Bastion terminal, clone the repository and navigate to the scripts directory:

   `git clone https://github.com/omoyal/rhacm-workshop.git`
   
   `cd rhacm-workshop/scripts/day2/01-certificate-policy`

2. Run the environment preparation script:

   `./01-lab-start.sh`
   
   *Verify that you receive the `[LAB READY]` output.*

---

### Step 2: Bind Cluster Set to Namespace (RHACM Console)
> **Why?** Policies live inside Namespaces on the Hub. For a policy to reach your managed clusters, its namespace must be granted explicit permission (Binding) to the target Cluster Set.

1. Open your browser and access the OpenShift Console.
2. Log in using **Red Hat Identity Management / Keycloak**.
3. Perspective switcher (Top): Ensure you are in the **All Clusters** view (Fleet Management perspective).
4. Left menu: Navigate to **Infrastructure** ➔ **Clusters**.
5. Select the **Cluster sets** tab and click on the **default** set.
6. In the **Details** card, locate **Namespace bindings** and click the **pencil icon** (Edit).
7. Select `policies-deploy` from the dropdown list and click **Save**.

---

### Step 3: Create the Monitoring Policy (Governance Dashboard)
> **Why?** We define what we are looking for (cert < 300h), where to look (`openshift-ingress`), and how to react (`Inform` only, no automatic changes).

1. Left menu: Navigate to **Governance** ➔ **Policies**.
2. Click the blue **Create policy** button.
3. **Details Tab:**
   * **Name:** `certificate-policy-console-ingress`
   * **Namespace:** `policies-deploy`
   * Click **Next**.
4. **Policy templates Tab:**
   * Click **Add policy template** and select: `Certificate management expiration`.
   * Change the template name to: `certificate-policy-console-ingress`.
   * Under **Include Namespace**: Remove `default` and add: `openshift-console` and `openshift-ingress`.
   * **Remediation action:** Select `Inform`.
   * **Severity:** Select `High`.
   * Click **Next**.
5. **Placement Tab:**
   * Select **New Placement** (Name is generated automatically).
   * Under **Cluster sets**, select `default`.
   * Click **Next**, review the summary, and click **Submit**.

---

### Step 4: Investigate the Violation (Detection in Action)
> **Why?** The Klusterlet agent samples the local cluster state and reports the violation back to the Hub. This demonstrates the power of a Single Pane of Glass.

1. In the **Governance** ➔ **Policies** screen, click on the `certificate-policy-console-ingress` policy.
2. Navigate to the **Results** tab.
3. Within 30-60 seconds, a red **Violations** status will appear on the `local-cluster`.
4. Read the error message: The system detected that the certificate in `openshift-ingress:router-certs` will expire in less than 300 hours.

---

### Step 5: Fix the Issue (Remediation)
> **Why?** We will simulate the Infrastructure team replacing the bad certificate with a valid 365-day certificate.

Return to your Bastion terminal and run the remediation script:

`./02-remediate-cert.sh`

---

### Step 6: Automatic Verification (Compliance Verified)
> **Why?** To see how RHACM detects fixes independently without requiring manual rescans.

1. Return to the **Results** tab in the RHACM Console.
2. Within a minute, the policy status will update to a green: **No violations**. The cluster is now compliant.

---

### Step 7: Environment Cleanup (Cleanup)
> **Why?** To leave a clean environment for the next exercise.

1. In your terminal, run:

   `./03-lab-finish.sh`

2. In the RHACM Console (under Governance ➔ Policies): Click the three dots (kebab menu) next to the policy, select **Delete**, and check the boxes to also delete the PlacementBindings and Placements.
