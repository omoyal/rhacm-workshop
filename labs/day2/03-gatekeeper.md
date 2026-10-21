# Lab 3: Integrate Gatekeeper with RHACM — Block the `:latest` Tag

**⏱️ Time:** ~45 minutes (the operator installation takes a few minutes on its own)

---

### 🧭 Overview & Context

> **Real-World Impact (The "Why")**
> `image: myapp:latest` works perfectly on Monday. On Tuesday someone pushes a new image, a pod restarts on another node, and production is now running different code than it was an hour ago, with no deployment, no review and no easy rollback. Pinning image tags is one of the first rules every platform team wants to **enforce**, not just recommend.
>
> In this lab you use the **RHACM Governance framework** to install the **Gatekeeper** admission controller on your fleet, then distribute a Gatekeeper rule that **blocks** any Deployment using the `latest` tag. You will also learn how to give a specific namespace an exemption, and how Gatekeeper denials show up as violations in the RHACM dashboard.

**Your fleet in this lab:**

| Cluster | Role | Label (set by the start script) |
|---|---|---|
| `local-cluster` | ACM hub | *(not targeted by this lab)* |
| 1st managed cluster (e.g. `cluster1`) | 🟡 Stage | `environment=stage` |
| 2nd managed cluster (e.g. `cluster2-sno`) | 🔴 Production | `environment=production` |

> 💡 The start script prints **your** exact cluster names. Use them wherever this guide shows `cluster1` / `cluster2-sno`.

---

### Step 1: Prepare the Environment

> **Purpose:** Label your managed clusters as stage and production, get admin access to both of them from the Bastion, and generate the lab files.

1. Open your **Bastion terminal**, update the workshop repository, and navigate to the lab scripts directory:

   ```bash
   cd ~/rhacm-workshop && git pull
   cd scripts/day2/03-gatekeeper
   ```

   > If you don't have the repository yet: `git clone https://github.com/omoyal/rhacm-workshop.git ~/rhacm-workshop`

2. Execute the environment preparation script:

   ```bash
   ./01-lab-start.sh
   ```

3. Confirm that the terminal outputs your cluster mapping:

   ```text
   ✅ [LAB READY] Environment successfully primed!

      🟡 Stage cluster      : cluster1   (environment=stage)
      🔴 Production cluster : cluster2-sno   (environment=production)
      📦 Operator catalog   : redhat-operators
      📁 Lab files          : /home/<user>/lab-work/03-gatekeeper
   ```

4. Load the lab helpers and move to the lab files directory:

   ```bash
   source ~/lab-work/03-gatekeeper/env.sh
   cd ~/lab-work/03-gatekeeper
   ```

   You now have three ways to talk to your fleet:

   | Command | Talks to |
   |---|---|
   | `oc` | the **ACM hub** (as before) |
   | `oc-stage` | the **stage** managed cluster |
   | `oc-prod` | the **production** managed cluster |

   > 💡 **Opened a new terminal?** Run the `source` command again. The helpers live only in the current shell.

---

### Step 2: Create the Policy Namespace on the Hub

> **Purpose:** RHACM policies are Kubernetes objects that live in a namespace **on the hub**. Create a dedicated namespace for this lab's policies.

```bash
oc new-project policy-gatekeeper
```

```text
Now using project "policy-gatekeeper" on server "https://api.<your-hub>:6443".
```

---

### Step 3: Verify Your Fleet in the Console

1. Log in to the **OpenShift Web Console** using **Keycloak**.

2. At the top navigation bar, set the perspective switcher to **Fleet management**.

3. Go to **Infrastructure** ➔ **Clusters** and verify that both managed clusters are in **Ready** status.

4. Click each managed cluster and look at its **Labels**. You should see `environment=stage` on one and `environment=production` on the other.

   > 💡 **Instructor Note:** Labels are how RHACM decides *where* things go. In a moment, a **Placement** will select clusters by `environment` instead of by name. Add a third production cluster tomorrow, label it, and it gets the same governance automatically.

---

### Step 4: Bind the Cluster Set to the Policy Namespace

> **Purpose:** A policy in `policy-gatekeeper` can only target clusters from a cluster set that is **bound** to that namespace (`ManagedClusterSetBinding`).

1. In **Infrastructure** ➔ **Clusters**, switch to the **Cluster sets** tab and select the **default** cluster set.

2. Locate the **Details** card, find **Namespace bindings**, and click the **pencil icon** (Edit).

3. Select `policy-gatekeeper` from the dropdown list, then click **Save**.

---

### Step 5: Install the Gatekeeper Operator with an RHACM Policy

> **Purpose:** Instead of logging in to each cluster and installing an operator by hand, describe the desired state once on the hub. RHACM installs it on every selected cluster and keeps it that way.

1. Go to **Governance** ➔ **Policies** and click **Create policy**.

2. At the top of the page, turn the **YAML** toggle on. Watch the YAML update as you fill in the wizard.

3. Configure **Section 1: Details**:
   - **Name:** `policy-gatekeeper-operator`
   - **Namespace:** `policy-gatekeeper`
   - Click **Next**.

4. Configure **Section 2: Policy templates**:
   - **Remediation:** select **Enforce**.
   - Click **Add policy template** and select **Install Red Hat Gatekeeper Operator policy**.
   - Verify the values below, then click **Next**:

   | Operator policy | Value |
   |---|---|
   | Name | `operatorpolicy-gatekeeper-operator` |
   | Installation Mode | All namespaces on the cluster (default) |
   | Installed Namespace | `openshift-operators` |

   | Operator Subscription | Value |
   |---|---|
   | Name | `gatekeeper-operator-product` |
   | Channel | `stable` |
   | Source | `redhat-operators` *(the catalog printed by the start script)* |
   | Source Namespace | `openshift-marketplace` |

5. Configure **Section 3: Placement**:
   - Click **New placement**. Name: `policy-gatekeeper-operator-placement`
   - **Cluster sets:** select `default`
   - Click **Add label expression** and set:
     - **Label:** `environment`
     - **Operator:** `equals any of`
     - **Values:** `stage`, `production`
   - Click **Next**.

   > 💡 **Instructor Note:** In the original Red Hat course, the hub also received Gatekeeper. Here the label expression keeps the policy **off the hub**. Without it, the `default` cluster set would also select `local-cluster`. Look at the YAML panel: this is a `Placement` with a `matchExpressions` predicate.

6. In **Section 4: Policy annotations**, leave the defaults (`NIST SP 800-53`, `CM Configuration Management`, `CM-2 Baseline Configuration`) and click **Next**.

7. In **Section 5: Review**, verify that the policy contains **three** templates (`operatorpolicy-gatekeeper-operator`, `gatekeeper`, `gatekeeper-status`), then click **Submit**.

---

### Step 6: Verify the Installation Across the Fleet

> **Purpose:** Watch RHACM install the operator, create the `Gatekeeper` instance, and report back from both clusters.

1. Open **Governance** ➔ **Policies** ➔ **`policy-gatekeeper-operator`** ➔ **Results** tab.

2. Wait **3 to 5 minutes**. You should end up with **6 rows** (3 templates × 2 clusters), all with **No violations**:

   ```text
   cluster1       No violations   gatekeeper-status
   cluster1       No violations   gatekeeper
   cluster1       No violations   operatorpolicy-gatekeeper-operator
   cluster2-sno   No violations   gatekeeper-status
   ...
   ```

3. Confirm from the Bastion that Gatekeeper is running on **both** managed clusters:

   ```bash
   oc-stage get csv -n openshift-operators | grep gatekeeper
   oc-prod get pods -n openshift-gatekeeper-system
   ```

   ```text
   gatekeeper-operator-product.v3.x.x   Gatekeeper Operator   3.x.x   Succeeded
   NAME                                             READY   STATUS    RESTARTS   AGE
   gatekeeper-audit-xxxxxxxxxx-xxxxx                1/1     Running   0          2m
   gatekeeper-controller-manager-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
   ```

4. And confirm that the **hub did not get it**:

   ```bash
   oc get csv -n openshift-operators | grep gatekeeper || echo "Not on the hub 👍"
   ```

---

### Step 7: Exclude the `app-stage` Namespace from All Constraints

> **Purpose:** Real fleets always need exceptions, such as a legacy team or a sandbox. Gatekeeper supports a global namespace exclusion, and you manage it **through the RHACM policy**, not by editing clusters directly.

1. Edit the policy on the hub:

   ```bash
   oc edit policy policy-gatekeeper-operator -n policy-gatekeeper
   ```

2. Find the `ConfigurationPolicy` named **`gatekeeper`**, and inside it the `Gatekeeper` object's `spec`. Add the **`config:`** block at the same indentation level as `webhook:`:

   ```yaml
   ...output omitted...
     - objectDefinition:
         apiVersion: policy.open-cluster-management.io/v1
         kind: ConfigurationPolicy
         metadata:
           name: gatekeeper
         ...output omitted...
             spec:
               audit:
                 logLevel: INFO
                 replicas: 1
               mutatingWebhook: Disabled
               validatingWebhook: Enabled
               webhook:
                 emitAdmissionEvents: Enabled
                 logLevel: INFO
                 replicas: 2
               config:                         # ⬅️ add from here
                 disableDefaultMatches: false
                 matches:
                   - excludedNamespaces:
                       - app-stage
                     processes:
                       - '*'                   # ⬅️ to here
   ...output omitted...
   ```

   > ⚠️ YAML is indentation-sensitive. If `oc edit` reopens the file with an error at the top, fix the indentation and save again. Prefer another editor? Run `export KUBE_EDITOR=nano` first.

3. Wait about a minute, then verify that the Gatekeeper operator on the **stage** cluster added the exclusion to its `Config` object:

   ```bash
   oc-stage get configs.config.gatekeeper.sh config -n openshift-gatekeeper-system -o yaml
   ```

   ```text
   ...output omitted...
       - excludedNamespaces:
         - app-stage
         processes:
         - '*'
   ...output omitted...
   ```

   > 💡 **Instructor Note:** You changed **one** object on the hub, and RHACM pushed the change to **every** cluster the policy targets. Nobody logged in to a managed cluster.

---

### Step 8: Deploy the "No `latest` Tag" Policy

> **Purpose:** Distribute the actual rule. The policy carries three templates:
> - a Gatekeeper **ConstraintTemplate** (the logic, written in Rego)
> - a **Constraint** (where the rule applies and what to do: `deny`)
> - a **ConfigurationPolicy** that turns Gatekeeper denials into RHACM violations

1. Make sure you are in the lab files directory:

   ```bash
   cd ~/lab-work/03-gatekeeper
   ```

2. Edit `policy-latest.yaml`. Scroll to the **`Placement`** resource at the bottom and replace the `CHANGE_ME` placeholders so the policy targets **both** environments:

   ```yaml
   kind: Placement
   metadata:
     name: placement-policy-gatekeeper-containerimage-latest
   spec:
     clusterSets:
       - default
     predicates:
       - requiredClusterSelector:
           labelSelector:
             matchExpressions:
               - key: environment
                 operator: In
                 values: [stage, production]
   ```

   > 💡 While you're in the file, read the Rego rule in the `ConstraintTemplate`. It is only a few lines. Can you see exactly which Kubernetes field it checks?

3. Create the policy:

   ```bash
   oc apply -f policy-latest.yaml
   ```

   ```text
   policy.policy.open-cluster-management.io/policy-gatekeeper-containerimage-latest created
   placementbinding.policy.open-cluster-management.io/binding-policy-gatekeeper-containerimage-latest created
   placement.cluster.open-cluster-management.io/placement-policy-gatekeeper-containerimage-latest created
   ```

4. In the console, go to **Governance** ➔ **Policies** ➔ **`policy-gatekeeper-containerimage-latest`** ➔ **Details**.

5. Verify that the **Placement** selects **2** clusters, your stage and production clusters, with **No violations**.

6. Confirm the constraint reached a managed cluster:

   ```bash
   oc-prod get constrainttemplates
   oc-prod get containerimagelatest
   ```

---

### Step 9: Test in Stage — Exempt vs. Enforced Namespace

> **Purpose:** See both sides of the rule on the same cluster: a namespace that is excluded, and one that is not.

1. Deploy the `stage-hello` application. It uses an image with the `latest` tag, in the **excluded** `app-stage` namespace:

   ```bash
   oc-stage create -f stage-hello.yaml
   ```

   ```text
   namespace/app-stage created
   deployment.apps/stage-hello created
   service/stage-hello created
   route.route.openshift.io/stage-hello created
   ```

   ✅ Gatekeeper **allowed** the Deployment because `app-stage` is excluded from all constraints.

2. Wait for the pod, then test the application:

   ```bash
   oc-stage rollout status deployment/stage-hello -n app-stage
   curl -s -o /dev/null -w '%{http_code}\n' "http://$(oc-stage get route stage-hello -n app-stage -o jsonpath='{.spec.host}')"
   ```

   ```text
   200
   ```

3. Now deploy the same application to the **`app-test`** namespace, which is **not** excluded:

   ```bash
   oc-stage create -f hello-app.yaml
   ```

   ```text
   namespace/app-test created
   service/hello-app created
   route.route.openshift.io/hello-app created
   Error from server (Forbidden): error when creating "hello-app.yaml": admission webhook
   "validation.gatekeeper.sh" denied the request: [containerimagelatest] Deployment/hello-app:
   container 'hello-app' is using the latest tag for its image
   (quay.io/redhattraining/hello-world-nginx:latest), which is an anti-pattern.
   ```

   ⛔ The Namespace, Service and Route were created, but the **Deployment was denied**.

4. In the console, open **`policy-gatekeeper-containerimage-latest`** ➔ **Results**. Within a minute, the **`policy-gatekeeper-admission-latest`** template shows **Violations** on your **stage** cluster. Click **View details** to see the Gatekeeper event behind it.

   > 💡 **Instructor Note:** Gatekeeper blocks the request **on the cluster**, and RHACM gives you **fleet-wide visibility** of who tried to break the rule and where. That combination is the whole point of integrating the two.

---

### Step 10: Test in Production — Deny, Fix, Deploy

> **Purpose:** Go through the developer experience: get denied, read the message, fix the manifest, and deploy successfully.

1. Deploy the `prod-hello` application to **production**:

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

2. Check **Governance** ➔ **`policy-gatekeeper-containerimage-latest`** ➔ **Results**. The production cluster now shows a violation as well.

3. Fix the manifest by pinning the image to the **`v1.0`** tag. Edit `prod-hello.yaml` so the container looks like this:

   ```yaml
   ...output omitted...
       spec:
         containers:
           - name: prod-hello
             image: quay.io/redhattraining/hello-world-nginx:v1.0
   ...output omitted...
   ```

4. Delete the orphaned `prod-hello` resources from the failed attempt. You can safely ignore the `NotFound` error for the Deployment, which was never created:

   ```bash
   oc-prod delete -f prod-hello.yaml
   ```

   ```text
   namespace "app-prod" deleted
   service "prod-hello" deleted
   route.route.openshift.io "prod-hello" deleted
   Error from server (NotFound): error when deleting "prod-hello.yaml": deployments.apps "prod-hello" not found
   ```

5. Create the application again. This time the policy **allows** it:

   ```bash
   oc-prod create -f prod-hello.yaml
   ```

   ```text
   namespace/app-prod created
   deployment.apps/prod-hello created
   service/prod-hello created
   route.route.openshift.io/prod-hello created
   ```

   > ⚠️ If you get `object is being deleted: namespaces "app-prod" already exists`, the namespace from the previous step is still terminating. Wait a few seconds and run the command again.

6. Test the application:

   ```bash
   oc-prod rollout status deployment/prod-hello -n app-prod
   curl -s -o /dev/null -w '%{http_code}\n' "http://$(oc-prod get route prod-hello -n app-prod -o jsonpath='{.spec.host}')"
   ```

   ```text
   200
   ```

---

### Step 11: Check Your Work

> **Purpose:** Get an automated grade for the lab. The check script is read-only: it changes nothing on your clusters.

1. Run the check script:

   ```bash
   cd ~/rhacm-workshop/scripts/day2/03-gatekeeper
   ./02-check.sh
   ```

2. Review your score. Every ❌ line comes with a 👉 hint pointing to the step to revisit:

   ```text
   ✅   5/5   Namespace 'policy-gatekeeper' exists on the hub
   ✅  10/10  Cluster set 'default' is bound to 'policy-gatekeeper'
   ...
   ✅   5/5   Gatekeeper denies ':latest' on both clusters (live dry-run test)

   ──────────────────────────────────────────────────────────────
   🏆 Score: 100/100  -  Perfect! Gatekeeper is enforced across your fleet.
   ──────────────────────────────────────────────────────────────
   ```

   Fix anything that failed and run the check again. 80 points or more is a pass.

---

### Step 12: Environment Cleanup

> **Purpose:** Remove the policies, Gatekeeper and the test applications from your fleet so the next lab starts clean.

1. **Delete the policies from the RHACM Console first:**
   - Navigate to **Governance** ➔ **Policies**.
   - For **each** of `policy-gatekeeper-operator` and `policy-gatekeeper-containerimage-latest`:
     - Click the actions menu (`⋮`) on the right and select **Delete**.
     - **Important:** Ensure both checkboxes are selected:
       - ☑ **Associated PlacementBindings**
       - ☑ **Associated Placements or PlacementRules**
     - Click **Delete**.

2. **Clean up everything else from the Bastion Terminal:**

   ```bash
   cd ~/rhacm-workshop/scripts/day2/03-gatekeeper
   ./03-lab-finish.sh
   ```

   ```text
   ✅ Environment is clean for the next lab!
   ```

   > 💡 **Instructor Note:** Deleting a policy does **not** uninstall what it installed. That's on purpose, because RHACM won't rip an operator out of production just because a policy was removed. The finish script therefore removes the Gatekeeper instance, operator and namespaces explicitly, and restores the cluster labels.

---

### 🎯 What You Achieved

- ✅ Installed an operator on a **selected part of the fleet** with a single RHACM policy, using labels rather than cluster names.
- ✅ Managed Gatekeeper's configuration (a namespace exclusion) **centrally**, through the policy.
- ✅ Enforced an organizational rule at **admission time** and saw every violation in **one dashboard**.

> 🧩 **Connecting the dots:** the same pattern (RHACM distributes, Gatekeeper enforces at admission, Governance reports) is how you enforce **mandatory labels**, **resource limits on every Deployment**, **forbidden SCC usage** and **required NetworkPolicies** across the whole fleet. Only the Rego rule changes.
