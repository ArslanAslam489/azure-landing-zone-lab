# ADR-001: Private endpoint for Azure SQL in the spoke, peered to the AKS-managed VNet

- **Status:** accepted
- **Context:** SEC-2091 requires Azure SQL to be reachable only privately from AKS, with public access disabled and no downtime. The cluster turned out to run in an AKS-managed VNet (`aks-vnet-xxxx`, 10.224.0.0/12, node RG), not in `vnet-spoke`.
- **Options:** (with cost, ops effort, skills)
  - **A. Endpoint in a new subnet of the AKS-managed VNet**, zone linked to it. Fewest resources. But it changes a VNet AKS owns; unsupported practice, and a cluster rebuild or upgrade can remove it.
  - **B. Endpoint in `vnet-spoke/snet-pe`, peering aks-vnet ↔ spoke, zone linked to both.** Endpoint stays with the workload in hub-spoke. Adds a peering (small per-GB charge) and touches the managed VNet only for the peering.
  - **C. Rebuild AKS into `snet-aks` in the spoke (bring your own VNet).** Correct long term, no extra peering. Costs a cluster rebuild and redeploy now.
- **Decision:** B for this ticket; C as the follow-up when the cluster is next rebuilt. Private DNS zone `privatelink.database.windows.net` is meant to be central in the hub (lab run created it in `rg-lab-spoke`). Rollout: endpoint → peering → zone + links → zone group → prove from pod → delete `AllowAzureServices` → disable public access.
- **Consequences:** (trade-offs accepted)
  - A peering into an AKS-managed VNet that must be re-created if the cluster is rebuilt.
  - Every new VNet that needs SQL must get a zone link, or it resolves publicly and fails.
  - Admin access to SQL now needs a network path (pipeline agent or Bastion jumpbox in the VNet), not a public IP rule.
  - The SQL password still lives in a Kubernetes Secret: SEC-2092 (workload identity + Entra-only auth).
