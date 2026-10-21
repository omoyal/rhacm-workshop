# Demo: Ensuring Database Encryption

**Goal:** Data of databases must be written **only to encrypted storage**. Any attempt to create a volume on unencrypted storage is rejected.

**File:** `Demo-DatabaseEncryption.yaml`. It creates the encrypted StorageClass `demo-encrypted-gp3`, and a rule for namespaces labeled `data-classification=sensitive`: volumes must use it.

> ⚠️ The StorageClass in the file is for **AWS** (`ebs.csi.aws.com`, `encrypted: "true"`). On other platforms, use that platform's encrypted storage class (for example ODF with encryption enabled).

---

### Steps

1. Hub console ➔ **+** (Import YAML) ➔ paste `Demo-DatabaseEncryption.yaml` ➔ **Create**.
2. On cluster1, create the database project:

   ```bash
   oc new-project demo-db
   oc label namespace demo-db data-classification=sensitive
   ```

---

### Show It Works (cluster1)

1. A volume on the default storage class: **rejected**:

   ```bash
   oc create -n demo-db -f - <<'YAML'
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: db-data
   spec:
     accessModes: [ReadWriteOnce]
     resources:
       requests:
         storage: 1Gi
   YAML
   ```

   ```text
   ... denied request: Data in this namespace must be stored on the encrypted StorageClass 'demo-encrypted-gp3'.
   ```

2. Add `storageClassName: demo-encrypted-gp3` under `spec:` and run it again: **allowed**.

3. cluster1 console ➔ **Storage** ➔ **StorageClasses** ➔ `demo-encrypted-gp3` ➔ **YAML**: `encrypted: "true"`.

---

### Key Points

- **At rest:** encryption is done by the storage, so it is transparent to the database. The policy guarantees that no sensitive data lands on unencrypted storage.
- **In transit:** require TLS between the application and the database, in the database configuration.
- Together with [ETCD Encryption](Demo-ETCD-Encryption.md), the database **passwords** (Secrets) are encrypted too.

### Cleanup

`oc delete project demo-db`, then delete the policy. RHACM removes the StorageClass and the rule it created.
