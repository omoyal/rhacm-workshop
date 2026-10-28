# Lab 5: Enable the RHACM Observability Stack

**⏱️ Time:** ~40 minutes (the start script can take 10–15 minutes the first time)

---

### 🧭 Overview & Context

> **Real-World Impact (The "Why")**
> With dozens of clusters, "which cluster is running out of CPU?" should not require logging in to each one. The **RHACM observability service** collects metrics from every managed cluster into one central store on the hub, and shows them in ready-made **Grafana** dashboards.
>
> In this lab you enable the RHACM observability stack, verify that its components are deployed on the hub and the managed clusters, analyze CPU and memory usage in Grafana, and then disable metrics collection for one cluster.

**Outcomes:**

- Enable the RHACM observability components.
- Verify the correct deployment of these components in the managed clusters.
- Locate and access the RHACM Grafana dashboard.
- Go to the Grafana dashboard and analyze the CPU and memory usage of the managed clusters.
- Disable the observability agent in one of the managed clusters.

---

### Before You Begin: Prepare the Environment

1. Open your **Bastion terminal**, update the workshop repository, and navigate to the lab scripts directory:

   ```bash
   cd ~/rhacm-workshop && git pull
   cd scripts/day2/05-observability
   ```

   > If you don't have the repository yet: `git clone https://github.com/omoyal/rhacm-workshop.git ~/rhacm-workshop`

2. Make sure that `oc` is logged in to your **ACM hub**:

   ```bash
   oc whoami
   ```

   If you get an error, log in again: in the hub web console, open the user menu (top right) ➔ **Copy login command** ➔ **Display Token**, and run the `oc login --token=...` command in the Bastion terminal.

3. Execute the environment preparation script. The first run installs OpenShift Data Foundation on the hub and can take **10–15 minutes**:

   ```bash
   ./01-lab-start.sh
   ```

4. Confirm that the terminal outputs:

   ```text
   ✅ [LAB READY] Environment successfully primed!
   ```

---

### Step 1: Create the `open-cluster-management-observability` Namespace in the Hub Cluster

1. In the **Bastion terminal**, confirm that you are logged in to the **ACM hub**:

   ```bash
   oc whoami --show-server
   ```

2. Create the `open-cluster-management-observability` namespace for the observability service. RHACM creates in this namespace the components that enable the observability service.

   ```bash
   oc create namespace open-cluster-management-observability
   ```

   ```text
   namespace/open-cluster-management-observability created
   ```

---

### Step 2: Create the `multiclusterhub-operator-pull-secret` Secret

1. Extract the secret named `pull-secret` from the `openshift-config` namespace, and store it in the `DOCKER_CONFIG_JSON` variable:

   ```bash
   DOCKER_CONFIG_JSON=$(oc extract secret/pull-secret -n openshift-config --to=-)
   ```

   ```text
   # .dockerconfigjson
   ```

2. Verify that the content of the `DOCKER_CONFIG_JSON` variable contains the `pull-secret` content:

   ```bash
   echo $DOCKER_CONFIG_JSON
   ```

   ```text
   {"auths": {"cloud.openshift.com": {"auth": ...output omitted...
   ```

3. Create the `multiclusterhub-operator-pull-secret` secret in the `open-cluster-management-observability` namespace:

   ```bash
   oc create secret generic multiclusterhub-operator-pull-secret \
     -n open-cluster-management-observability \
     --from-literal=.dockerconfigjson="$DOCKER_CONFIG_JSON" \
     --type=kubernetes.io/dockerconfigjson
   ```

   ```text
   secret/multiclusterhub-operator-pull-secret created
   ```

---

### Step 3: Verify the Object Storage

The start script installed **OpenShift Data Foundation** and deployed the **Multicloud Object Gateway** component, which provides the S3 endpoint in the hub cluster.

1. Verify that the `StorageCluster` object is ready:

   ```bash
   oc get storagecluster -n openshift-storage
   ```

   ```text
   NAME                 AGE   PHASE   ...
   ocs-storagecluster   8m    Ready   ...
   ```

2. Verify that the `NooBaa` object is ready:

   ```bash
   oc get noobaa -n openshift-storage
   ```

   ```text
   NAME     ...   PHASE   AGE
   noobaa   ...   Ready   6m
   ```

3. Verify that the `openshift-storage.noobaa.io` storage class exists:

   ```bash
   oc get storageclasses -o custom-columns='NAME:metadata.name,PROVISIONER:provisioner'
   ```

   ```text
   NAME                          PROVISIONER
   ...output omitted...
   openshift-storage.noobaa.io   openshift-storage.noobaa.io/obc
   ```

---

### Step 4: Create the Persistent Object Store for the Observability Service

1. Change to the `~/DO0014L/labs/observability-enable/` directory:

   ```bash
   cd ~/DO0014L/labs/observability-enable/
   ```

2. Edit the `obc.yaml` file and modify the placeholder text to match the following content:

   ```yaml
   apiVersion: objectbucket.io/v1alpha1
   kind: ObjectBucketClaim
   metadata:
     name: thanos-obc
     namespace: open-cluster-management-observability
   spec:
     storageClassName: openshift-storage.noobaa.io
     generateBucketName: observability-bucket
   ```

3. Create the `thanos-obc` object bucket claim:

   ```bash
   oc apply -f obc.yaml
   ```

   ```text
   objectbucketclaim.objectbucket.io/thanos-obc created
   ```

4. Verify that the `thanos-obc` object bucket claim exists in the `open-cluster-management-observability` namespace, and that it displays `Bound` in the `PHASE` column:

   ```bash
   oc get objectbucketclaim -n open-cluster-management-observability
   ```

   ```text
   NAME         STORAGE-CLASS                 PHASE   ...
   thanos-obc   openshift-storage.noobaa.io   Bound
   ```

---

### Step 5: Retrieve the S3 Bucket Information and Credentials

When an object bucket claim is created, OpenShift Data Foundation creates, with the same name, a matching secret and a configuration map, which contain the bucket information and credentials. You use this data in the next step.

1. Retrieve the bucket name from the generated configuration map:

   ```bash
   oc extract --to=- cm/thanos-obc -n open-cluster-management-observability
   ```

   ```text
   # BUCKET_HOST
   s3.openshift-storage.svc
   # BUCKET_NAME
   observability-bucket-030b2b89-6c7e-4883-a26e-ea8939dfc875
   # BUCKET_PORT
   443
   ...output omitted...
   ```

   The `BUCKET_NAME` in the preceding output is different on your system.

2. Retrieve the bucket credentials from the generated secret:

   ```bash
   oc extract --to=- secret/thanos-obc -n open-cluster-management-observability
   ```

   ```text
   # AWS_ACCESS_KEY_ID
   nOvOOrBFBlF4Bc1NZaIv
   # AWS_SECRET_ACCESS_KEY
   sc8Z3KPnF8Ik035inA0ji9Nkz3g2hBMnVe7EFWIT
   ```

   The credentials in the preceding output are different on your system.

3. Identify the public URL for the S3 endpoint from the `s3` route in the `openshift-storage` namespace:

   ```bash
   oc get route s3 -n openshift-storage
   ```

   ```text
   NAME   HOST/PORT                                      ...
   s3     s3-openshift-storage.apps.<your-hub-domain>    ...
   ```

---

### Step 6: Create the `thanos-object-storage` Secret

1. Edit the `secret.yaml` file and update the placeholder text. Use the S3 credentials, the S3 endpoint URL, and the bucket name from the previous step:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: thanos-object-storage
     namespace: open-cluster-management-observability
   type: Opaque
   stringData:
     thanos.yaml: |
       type: s3
       config:
         bucket: observability-bucket-030b2b89-6c7e-4883-a26e-ea8939dfc875
         endpoint: s3-openshift-storage.apps.<your-hub-domain>
         insecure: true
         access_key: nOvOOrBFBlF4Bc1NZaIv
         secret_key: sc8Z3KPnF8Ik035inA0ji9Nkz3g2hBMnVe7EFWIT
   ```

2. Create the `thanos-object-storage` secret:

   ```bash
   oc apply -f secret.yaml
   ```

   ```text
   secret/thanos-object-storage created
   ```

---

### Step 7: Create the `MultiClusterObservability` Custom Resource Instance

1. Edit the `mcobs.yaml` file and modify the placeholder text to match the following content. The `storageClass` field is already set to the default storage class of your hub:

   ```yaml
   apiVersion: observability.open-cluster-management.io/v1beta2
   kind: MultiClusterObservability
   metadata:
     name: observability
   spec:
     observabilityAddonSpec:
       enableMetrics: true
     storageConfig:
       metricObjectStorage:
         key: thanos.yaml
         name: thanos-object-storage
       storageClass: <your hub default storage class>
       alertmanagerStorageSize: 1Gi
       compactStorageSize: 1Gi
       receiveStorageSize: 1Gi
       ruleStorageSize: 1Gi
       storeStorageSize: 1Gi
   ```

2. Create the `MultiClusterObservability` object:

   ```bash
   oc apply -f mcobs.yaml
   ```

   ```text
   multiclusterobservability.observability.open-cluster-management.io/observability created
   ```

3. Verify that the `multicluster-observability-operator` deployment runs the `multicluster-observability-operator` pod in the `open-cluster-management` namespace:

   ```bash
   oc get deploy multicluster-observability-operator -n open-cluster-management
   ```

   ```text
   NAME                                  READY   UP-TO-DATE   AVAILABLE   AGE
   multicluster-observability-operator   1/1     1            1           5m
   ```

4. Verify that all the pods in the `open-cluster-management-observability` namespace display `Running` in the `STATUS` column. It can take a few minutes for the pods to reach the `Running` status.

   ```bash
   oc get po -n open-cluster-management-observability
   ```

   ```text
   NAME                                               READY   STATUS    ...
   observability-alertmanager-0                       4/4     Running
   observability-grafana-7c8ddc4d5-bnbwn              3/3     Running
   observability-observatorium-api-6f9748959-xbj2j    1/1     Running
   ...output omitted...
   ```

---

### Step 8: Analyze the CPU and Memory Usage of the Managed Clusters in Grafana

1. Log in to the **OpenShift Web Console** of your hub using **Keycloak**.

2. Set the perspective switcher to **Fleet management**, and go to **Infrastructure** ➔ **Clusters**.

3. Click the **Grafana** link in the upper-right corner.

4. In the new browser tab that opens, log in with the same **Keycloak** credentials.

5. Grafana loads the **Home: Dashboards ➔ ACM - Clusters Overview** dashboard by default. Scroll down to the **Capacity / Utilization** section, and locate the CPU and memory usage of `local-cluster` and `cluster1`. The data can take up to seven minutes to appear after the observability service is installed.

---

### Step 9: Disable the Metrics Collection from `cluster1`

This feature is useful to avoid overloading the observability service with metrics from clusters that are used for stage environments, for example.

1. Switch to the RHACM web console, and go to **Infrastructure** ➔ **Clusters**.

2. In the **Cluster list** tab, click **cluster1**.

3. On the **cluster1** page, click the **Add-ons** tab. Locate the **observability-controller** add-on in the list.

4. Switch to the terminal window, and change to the home directory:

   ```bash
   cd ~
   ```

5. List the managed clusters:

   ```bash
   oc get managedclusters
   ```

   ```text
   NAME            HUB ACCEPTED   MANAGED CLUSTER URLS   ...
   cluster1        true           https://api.<cluster1-domain>:6443
   cluster2-sno    true           https://api.<cluster2-domain>:6443
   local-cluster   true           https://api.<hub-domain>:6443
   ```

6. Add the `observability=disabled` label to the `ManagedCluster` custom resource named `cluster1`:

   ```bash
   oc label managedcluster cluster1 observability=disabled -n open-cluster-management
   ```

   ```text
   managedcluster.cluster.open-cluster-management.io/cluster1 labeled
   ```

7. Load the `oc-cluster1` command, which runs `oc` against `cluster1` as the admin user:

   ```bash
   source ~/DO0014L/labs/observability-enable/env.sh
   ```

8. Verify that no pods are running in the `open-cluster-management-addon-observability` namespace on `cluster1`. It can take a minute for the pods to be removed:

   ```bash
   oc-cluster1 get pod -n open-cluster-management-addon-observability
   ```

   ```text
   No resources found in open-cluster-management-addon-observability namespace.
   ```

9. Switch to the RHACM web console, and go to **Infrastructure** ➔ **Clusters** ➔ **cluster1** ➔ **Add-ons**. Verify that the **observability-controller** add-on is not in the list.

   The Grafana dashboard can show cached information about `cluster1` after disabling the observability add-on. All the information about `cluster1` disappears in a few hours.

---

### Check Your Work

1. Run the check script:

   ```bash
   cd ~/rhacm-workshop/scripts/day2/05-observability
   ./02-check.sh
   ```

2. Review your score. Every ❌ line includes a 👉 hint that points to the step to fix:

   ```text
   ──────────────────────────────────────────────────────────────
   🏆 Score: 100/100  -  Perfect! Observability is enabled across your fleet.
   ──────────────────────────────────────────────────────────────
   ```

---

### Finish

Run the cleanup script. This step is important to ensure that resources from this exercise do not impact upcoming exercises.

```bash
cd ~/rhacm-workshop/scripts/day2/05-observability
./03-lab-finish.sh
```

```text
✅ Environment is clean for the next lab!
```
