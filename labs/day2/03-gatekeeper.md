# Lab 3: Gatekeeper admission control with RHACM

**Status: drafted and statically reviewed; target execution pending.**
**Time:** 35 minutes after installation preparation.

## Objective and scenario
Use RHACM governance to manage Gatekeeper, exclude one namespace from constraint processing, and reject application deployments that explicitly use `:latest`. These are the outcomes of DO432 exercise 3.10, adapted to your independent environment.

You are the platform operator. The same application is allowed in an exempt stage namespace but must use a pinned image in production.

## Prerequisites and starting state
Complete [environment preparation](00-finale-preparation.md). Gatekeeper must already run on both targets, installed through the reviewed `ws-gatekeeper-engine` Policy. Keep the root repository open in the bastion. No `ws-*` namespace or constraint from a previous attempt should remain. The stage and production clusters must be distinct.

Use the context values from your local configuration. In the commands below, replace `<hub-context>`, `<stage-context>` and `<prod-context>` with those values. Do not type the angle brackets.

## 1. Prepare isolated resources (4 minutes)
**Purpose:** create only the namespaces and scope used by this exercise.
```bash
bash scripts/day2/03-gatekeeper/01-lab-start.sh
```
Expected: `LAB READY`. Generated files appear in `.workshop/`. Read `gatekeeper-rules.json`, `gatekeeper-report.json` and the four application manifests.

In Governance, inspect the installation Policy's Results. On each managed cluster inspect the Gatekeeper CR and runtime pods. Explain why installing the Operator alone is insufficient.

## 2. Distribute the constraint (7 minutes)
**Purpose:** connect the RHACM root Policy to local admission enforcement.
The rule checks `spec.containers` on Pods and `spec.template.spec.containers` on Deployments. It intentionally checks only explicit `:latest` tags in regular containers. Untagged images, initContainers, ephemeral containers and other workload kinds are outside this teaching example.
```bash
oc --context <hub-context> apply -f .workshop/gatekeeper-rules.json
oc --context <hub-context> apply -f .workshop/gatekeeper-report.json
python3 scripts/day2/workshop.py check-gatekeeper
```
If checks are not ready, inspect Policy Results, the ConstraintTemplate status and the generated constraint before retrying. Check that Placement selects exactly your stage and production clusters.

On production:
```bash
oc --context <prod-context> get constrainttemplate wscontainertags -o yaml
oc --context <prod-context> get wscontainertags ws-no-latest -o yaml
```
Success: the template has no reported compilation errors and effective `enforcementAction` is `deny`.
The template uses `import rego.v1`. Validate this against the installed Gatekeeper/OPA version in rehearsal; do not silently change the rule during delivery.

## 3. Compare normal and exempt namespaces (8 minutes)
First attempt an invalid deployment in stage:
```bash
oc --context <stage-context> apply -f .workshop/stage-bad.json
```
Expected: a Gatekeeper admission denial mentioning `ws-no-latest`. Confirm that the Deployment was not created.

Next review `.workshop/engine-with-exclusion.json`, prepared before the lab. Compare its Gatekeeper CR configuration with the initial installation file. The added namespace is `ws-stage-exempt`, with `processes: ['*']`. Apply the change through the owning RHACM installation policy:
```bash
oc --context <hub-context> apply -f .workshop/engine-with-exclusion.json
oc --context <stage-context> get configs.config.gatekeeper.sh config \
  -n openshift-gatekeeper-system -o yaml
```
Wait until the exclusion appears, then:
```bash
oc --context <stage-context> apply -f .workshop/stage-exempt.json
oc --context <stage-context> rollout status deployment/hello \
  -n ws-stage-exempt --timeout=180s
```
Expected: admission succeeds and the workload becomes available if the image is accessible. The same installation policy distributes the exemption to both workshop targets; only stage has that namespace. This is not an environment-aware exemption. It applies to all constraints for that namespace on each selected cluster.

## 4. Reject and correct production (8 minutes)
```bash
oc --context <prod-context> apply -f .workshop/prod-bad.json
```
Expected: admission denial. Inspect the failing request and identify the exact field to change. Now review the good manifest, which uses the verified digest:
```bash
oc --context <prod-context> apply -f .workshop/prod-good.json
oc --context <prod-context> rollout status deployment/hello -n ws-prod --timeout=180s
```
Expected: the deployment is admitted and available. Gatekeeper evaluates the image reference; it does not verify registry reachability or image vulnerability status.

## 5. Verify reporting and explain the outcome (5 minutes)
Inspect `ws-admission-report` in Governance and target Events:
```bash
oc --context <prod-context> get events -n openshift-gatekeeper-system -o yaml
```
Find the Event with constraint name `ws-no-latest` and action `deny`. The reporting Policy uses `mustnothave` with `inform`, so a matching Event produces NonCompliant. Keep its parent Policy in inform as well.

If no event is found, verify event emission, the actual event namespace, annotations and retention. Some operator configurations emit events in the involved resource's namespace. Adapt the report filter to observed behavior during rehearsal.

A successful retry does not delete a previous violation Event. The reporting Policy can remain NonCompliant until that Event expires. Audit of stored objects and reporting of rejected requests are different evidence sources.

**Checkpoint:** Why was the same `latest` image allowed in one namespace and rejected in another? Which component made the admission decision?

## Cleanup and dependencies
Keep Gatekeeper installed. The capstone uses different namespaces, so the image constraint does not interfere with it.
```bash
bash scripts/day2/03-gatekeeper/03-lab-finish.sh
```
The script removes root Policies, waits for hub replicas to disappear, then deletes only workshop-owned constraints/templates and namespaces. Remove the `ws-stage-exempt` exclusion through the installation Policy if it is no longer needed; preserve other exclusions. Do not uninstall the Operator or delete its namespace as routine cleanup.

If the script stops, investigate the reported object rather than using a broad delete command. Shared labels are restored only after all labs and demos finish.

## Optional hints
See [Gatekeeper hints](03-gatekeeper-hints.md) only after trying the checkpoint yourself.
