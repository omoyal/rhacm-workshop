# Day 2 finale: environment preparation

**Status: drafted and statically reviewed. NOT executed in the target environment.**
Complete this preparation with the instructor before starting the timed labs.
The tested-results column in the instructor checklist is deliberately empty.

## Environment and scope
Each participant uses their own independent environment. You need a hub and two available managed OpenShift clusters. The example observed on 21 October 2026 had RHACM 2.17.3, hub OpenShift 4.22.17, and managed clusters `cluster1` and `cluster2-sno`. Do not assume the same context names, versions or state in your own environment.

The curriculum is DO432 2.13. These labs adapt its objectives to the available environment. They do not use classroom `lab start`, `lab finish`, classroom credentials, the classroom registry or the `gls-catalog-cs` catalog.

## 1. Obtain the workshop files
If the instructor has published this package:
```bash
git clone https://github.com/omoyal/rhacm-workshop.git
cd rhacm-workshop
```
If you already have the repository, use `git pull --ff-only` from its root after saving local changes. Until publication, use the `repository/` folder from the delivered ZIP as your working root. Do not assume the new files are already on GitHub.

Requirements on the bastion: `bash`, `python3` (standard library only), `oc`, and optionally `git`. No automatic package installers are included.

## 2. Establish three authenticated contexts
Use your environment's normal secure login process to establish hub, stage and production contexts. Do not put credentials in scripts or Git.
```bash
oc config get-contexts
oc --context <hub-context> get managedclusters
```
The instructor must help map each context to the matching managed cluster API endpoint. The preflight compares endpoints and stops on a mismatch. All scripts pass `--context` explicitly and do not change the current context.

Copy and edit the configuration:
```bash
cp workshop-config.example.json workshop-config.json
```
Set the three context names. Set stage/prod managed cluster names. Suggested roles: `cluster2-sno` for stage, `cluster1` for production. These roles are for the exercise only.

## 3. Select an image and pin it
The workloads use Python's built-in HTTP server and HTTP client. Use the same Red Hat UBI Python image with a `latest` reference for the rejected request and with an immutable digest for successful requests.
```bash
oc image info registry.access.redhat.com/ubi9/python-312:latest -o json
```
Inspect the returned `digest` (and platform information) and set `image_pinned` to `registry.access.redhat.com/ubi9/python-312@sha256:<verified-digest>`. Do not copy a digest from another image or invent one. A digest must be resolved and image pulls tested during the instructor rehearsal. If registry access is unavailable, use an approved mirror with both references available and the same Python functionality.

The scripts reject placeholders and non-digest `image_pinned` values. They do not automatically pull or mirror images.

## 4. Read-only preflight
```bash
python3 scripts/day2/workshop.py preflight
```
Expected: all three context identities resolve, all three clusters are accessible, both managed cluster API endpoints match, and their Governance add-ons are Available. Permissions must allow the scoped cluster administration tasks used by this isolated lab.

This check does not prove that image pulls, networking, SCC behavior or the exercises work.

## 5. Install Gatekeeper before the 35-minute lab
Review package, channel, catalog source and namespace in `workshop-config.json` against each target's Operator catalog. The supplied values are candidates, not an observed installation.
```bash
python3 scripts/day2/workshop.py prepare-engine
```
This creates workshop scope resources and generates `.workshop/engine-install.json`. It stops if it finds an existing Gatekeeper CRD, so that it cannot take over an unrelated installation. For an existing installation, the instructor must review the CR, policy ownership, exclusions and webhook event settings and adapt the generated examples manually.

Read the generated file. It contains an RHACM Policy with an OperatorPolicy and a ConfigurationPolicy for the Gatekeeper CR, plus Placement and PlacementBinding. It selects only the two workshop managed clusters.
```bash
oc --context <hub-context> apply -f .workshop/engine-install.json
```
Observe Governance Results and the target Operator installations. During initial installation a missing Gatekeeper API can be transient. Do not deploy constraints before the runtime is ready.
```bash
python3 scripts/day2/workshop.py engine-ready
```
Expected: Gatekeeper CR exists and audit/controller-manager pods are Ready on both targets. If actual workload names differ, inspect the namespace and update the readiness check before the workshop.

Installation timing is excluded from the 35-minute lab. Participants review the installation policy and verify it during the lab; a full installation exercise needs extra time.

## File conventions
- `labs/day2/`: participant Markdown instructions.
- `scripts/day2/`: preparation, verification and cleanup helpers.
- `.workshop/`: generated Kubernetes manifests and local state. JSON is a valid Kubernetes manifest format and can be inspected with `oc ... -o yaml` after application.
- `workshop-config.json`: local, ignored by Git; contains context names and settings, never passwords or tokens.

Do not run all scripts in numeric order blindly. Follow the lab guide and pause at each checkpoint. Each script checks ownership before overwriting a named resource. Cleanup leaves Gatekeeper installed for subsequent use.
