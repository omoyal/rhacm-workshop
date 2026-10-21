# RHACM Day 2 finale package

**Draft for joint validation. No exercise has been executed in the target environment.**

Merge these new files into the existing repository without replacing its existing README or sample lab. The files use its `labs/day2` and `scripts/day2` structure.

1. [Preparation](labs/day2/00-finale-preparation.md)
2. [Lab 3: Gatekeeper](labs/day2/03-gatekeeper.md)
3. Instructor-led lesson 3.11 in the PowerPoint
4. [Lab 4: Governance troubleshooting](labs/day2/04-governance-troubleshooting.md)
5. Instructor demonstrations: SCC/RBAC and etcd encryption

Each participant runs the labs on their own environment. No shared cluster names, passwords, tokens or kubeconfigs are embedded. Context names and image digests are configured locally.

The scripts prepare scenarios, generate readable Kubernetes JSON manifests, verify evidence and clean up only named workshop resources. They are not a substitute for the diagnostic steps in the guides.

Instructor solutions, the private rehearsal checklist and speaker notes are delivered separately. Do not copy the instructor folder or the presentation with speaker notes into the public participant repository.

Source basis: DO432 RHACM 2.13, exercises 3.10 and 3.12, lesson 3.11. These are original workshop adaptations. Official course PDFs and screenshots are not included in the repository payload.
