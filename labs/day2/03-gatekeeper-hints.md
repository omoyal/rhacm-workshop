# Gatekeeper hints
1. No constraint on a target: compare PlacementDecision, namespace binding and add-on availability.
2. ConstraintTemplate rejected: inspect `status.byPod[].errors`; a YAML parse success does not prove Rego compilation.
3. Invalid request allowed: inspect the effective constraint action, matched resource kind, namespace list and generated Gatekeeper Config.
4. Exclusion disappears: identify the Policy that owns the Gatekeeper CR and update its desired state.
5. No admission report: look at the actual Event before changing the reporting filter.
6. Allowed but not Running: inspect Pod Events. Admission success does not guarantee image pulls or scheduling.
