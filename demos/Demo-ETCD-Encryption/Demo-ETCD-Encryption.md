# Demo: Enforcing ETCD Encryption

**Goal:** Make sure secrets, ConfigMaps and other API data are stored **encrypted** in etcd on every cluster.

**File:** `Demo-ETCD-Encryption.yaml`

---

### Steps (Console)

1. Hub console ➔ **Governance** ➔ **Policies** ➔ **Create policy**.
2. **Details:** Name `demo-etcd-encryption`, Namespace `demo-policies` ➔ **Next**.
3. **Policy templates:** Remediation **Enforce** ➔ **Add policy template** ➔ **Enable etcd encryption** ➔ **Next**.
4. **Placement:** **New placement** ➔ Cluster sets `default` ➔ **Add label expression**: `name` **equals any of** `cluster1` ➔ **Next**.
5. **Next** ➔ **Submit**.

> Or apply the file: `oc apply -f Demo-ETCD-Encryption.yaml`. It also includes a status check that turns green only when encryption is **complete**.

---

### Show It Works

1. **Governance** ➔ `demo-etcd-encryption` ➔ **Results**: `cluster1` is compliant.
2. On cluster1, check the encryption progress:

   ```bash
   oc get openshiftapiserver -o=jsonpath='{range .items[0].status.conditions[?(@.type=="Encrypted")]}{.reason}{"\n"}{.message}{"\n"}{end}'
   ```

   ```text
   EncryptionCompleted
   All resources encrypted: routes.route.openshift.io
   ```

---

### Key Points

- The policy sets `spec.encryption.type: aescbc` on the `APIServer` resource. OpenShift does the rest.
- Encryption takes **10 to 20 minutes** or more, and the API servers roll out during that time. Do not apply it right before a demo of something else on the same cluster.
- Turning encryption off again is also a full re-write of the data. Treat it as a permanent setting.

### Cleanup

Delete the policy. This does **not** turn encryption off (which is what you want).
