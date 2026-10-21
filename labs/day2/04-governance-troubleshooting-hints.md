# Troubleshooting hints
1. A Placement chooses from sets bound to its namespace. Inspect both the chosen set and the set's selector.
2. An empty PlacementDecision after selecting the correct set can mean the set has no matching members.
3. `NetworkPolicy.spec.ingress[].from[].podSelector` in this example selects source Pods in the same namespace. Compare that selector with the Deployment's Pod template, not only its top-level metadata.
4. A default-deny ingress policy does not block DNS egress by itself. Check endpoint readiness before diagnosing selectors.
5. Read ReplicaSet Events for a quota rejection. Count the API Pods AND the two client Pods.
6. The ConfigurationPolicy enforcing a ResourceQuota is the source of desired state. Repair it rather than repeatedly editing the target object.
