# Lab 4: Investigate and fix a governance incident

**Status: drafted and statically reviewed; target execution pending.**
**Time:** 35 minutes. Use instructor hints if needed to protect discussion time.

## Objectives
Troubleshoot common RHACM governance issues. Correct a Policy's target set and its membership, preserving the intent of DO432 exercise 3.12. Then verify application connectivity and resource constraints required by the customer scenario.

## Starting state
Complete the shared environment preparation. You need the hub and both managed cluster contexts, working images, Governance add-ons, and permission to manage workshop resources. Gatekeeper can stay installed, but Lab 3 constraints must not target `ws-app`.

The scripts use label-selected workshop ClusterSets. They preserve the clusters' existing exclusive set membership, which other labs may depend on. The course uses an exclusive set transfer; the diagnostic goal remains the same: verify both the selected set and its actual members.

## 1. Prepare the incident (3 minutes)
From the repository root:
```bash
bash scripts/day2/04-governance-troubleshooting/01-lab-start.sh
```
Expected: `LAB READY`. On production, `api`, `client` and `outsider` Deployments have one available replica each. A namespace audit policy deliberately targets the wrong set. Network communication is deliberately blocked.

The broad policy is **inform only**. Application network and quota controls use a separate production-only Placement.

## 2. Correct policy scope (10 minutes)
**Request:** `ws-production-baseline`, in hub namespace `ws-governance`, must target only your production managed cluster via `ws-production`.

Use Governance > Policies > Details/Results and these commands:
```bash
oc --context <hub-context> get policy ws-production-baseline -n ws-governance -o yaml
oc --context <hub-context> get placement ws-production-targets -n ws-governance -o yaml
oc --context <hub-context> get placementdecisions -n ws-governance -o yaml
oc --context <hub-context> get managedclusterset ws-production -o yaml
oc --context <hub-context> get managedclustersetbindings -n ws-governance
```
Tasks:
1. Identify the current targets and the incorrect `spec.clusterSets` value.
2. Correct that field to select `ws-production`.
3. Inspect the new PlacementDecision. Why are there now no targets?
4. Read the production set's selector. Add its required label to **only** your production ManagedCluster on the hub.
5. Verify that the final PlacementDecision contains exactly that cluster.

Do not change the built-in `cluster.open-cluster-management.io/clusterset` label. This exercise uses `workshop.rhacm.io/environment=production` for membership in a separate label-selected set.

**Success evidence:** correct Placement and exactly one decision. Compliant alone does not prove that the right cluster was selected.

## 3. Diagnose blocked application traffic (9 minutes)
**Request:** `client` may reach `api` on TCP 8080. `outsider` must remain blocked.

First examine the source/destination labels, Service endpoints and NetworkPolicies:
```bash
oc --context <prod-context> get pods -n ws-app --show-labels
oc --context <prod-context> get service api -n ws-app -o yaml
oc --context <prod-context> get endpointslices -n ws-app
oc --context <prod-context> get networkpolicies -n ws-app -o yaml
python3 scripts/day2/workshop.py network client deny
```
Identify the mismatch between the permitted client selector and the client's Pod template labels. Correct the Deployment template, then wait for its rollout. Do not remove the default-deny policy or allow all sources.

Verify both directions of the requirement:
```bash
python3 scripts/day2/workshop.py network client allow
python3 scripts/day2/workshop.py network outsider deny
```
Expected: HTTP 200 from `client`; a connection timeout from `outsider`. A DNS or missing-command error is not proof of NetworkPolicy enforcement. The checker only accepts an explicit timeout for the denial case.

This is application flow mapping and testing, not automatic discovery of all existing cluster traffic.

## 4. Diagnose failed scaling (9 minutes)
**Request:** scale `api` from one replica to three while retaining the per-container resource limits.
```bash
oc --context <prod-context> scale deployment/api -n ws-app --replicas=3
oc --context <prod-context> get deployment,replicaset,pods -n ws-app
oc --context <prod-context> get events -n ws-app --sort-by=.lastTimestamp
oc --context <prod-context> describe resourcequota ws-budget -n ws-app
oc --context <prod-context> get limitrange ws-defaults -n ws-app -o yaml
```
All three workloads request 50m CPU and 64Mi per container and have limits of 100m CPU and 128Mi. Three API Pods plus two client Pods require five Pods in total. The initial quota allows only four.

Find the controller that reports the failed Pod creation. The Deployment update may succeed even though its ReplicaSet cannot create every requested Pod.

Update the **owning RHACM Policy** `ws-app-controls` in `ws-governance`, or its generated source `.workshop/app-controls.json`, to use:
- `pods: "6"`
- `requests.cpu: "300m"`, `requests.memory: "384Mi"`
- `limits.cpu: "600m"`, `limits.memory: "768Mi"`

Review and apply the updated source on the hub if you edited the file. Wait for propagation and successful scaling. Keep the workload requests/limits and LimitRange unchanged. Editing the target ResourceQuota directly can be reverted by enforcement.

## 5. Final evidence and debrief (4 minutes)
```bash
bash scripts/day2/04-governance-troubleshooting/02-check.sh
```
Record:
- Which two configuration errors affected policy targeting?
- Which label mismatch caused the network failure?
- Why did scaling fail even though the Deployment existed?
- Which desired-state object did you change for the quota fix?

## Cleanup
```bash
bash scripts/day2/04-governance-troubleshooting/03-lab-finish.sh
```
This removes workshop policy definitions before deleting managed resources. The script deletes `ws-app` only if it has the workshop ownership label. Keep other training namespaces and Operators intact. Retain local configuration for the demos.

## Hints
See [troubleshooting hints](04-governance-troubleshooting-hints.md) after attempting diagnosis.
