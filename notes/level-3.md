# Level 3 — Private endpoint + private DNS

## Ticket
> **SEC-2091 — P2 — from Security / external pentest**
> We reached the SQL server on port 1433 from the internet. The firewall allows all Azure services (including other customers').
> The AKS app uses a SQL password in a Kubernetes Secret.
> **Required:** reachable only privately from AKS, public network access disabled, no app downtime.

Script: [scripts/level-3.sh](../scripts/level-3.sh) · App: [app/report-api](../app/report-api) · Decision: [ADR-001](../adr/adr-001-private-endpoint-placement.md)

## Design
```
 aks-vnet-xxxx (10.224.0.0/12, AKS-managed)        vnet-spoke (10.1.0.0/16)
 ┌──────────────────────────┐   peering    ┌──────────────────────────────────┐
 │ AKS node → report-api pod│◄────────────►│ snet-pe 10.1.2.0/24              │
 └────────────┬─────────────┘              │   pe → labsqlprivate  10.1.2.4   │──► Azure SQL
              │ DNS                        └───────────────┬──────────────────┘   (public access: Disabled)
              ▼                                            │
   168.63.129.16 ──► privatelink.database.windows.net ◄────┘  linked to both VNets
                     A  labsqlprivate → 10.1.2.4 (zone group)
```

Rollout order (zero downtime):
1. Private endpoint in `snet-pe` (public access still on)
2. Peering aks-vnet ↔ vnet-spoke (AKS wasn't in the spoke)
3. Private DNS zone, linked to both VNets
4. Zone group → A record
5. **Gate:** pod `/dns` = 10.1.2.4 and `/reports` returns data
6. Delete `AllowAzureServices`, disable public network access
7. Prove again from pod and laptop

## What happened
- **Build blockers before the ticket:** a laptop hard-restart corrupted the .NET 8 install (`hostfxr.dll` 0x800700C1, no `sdk` folder); reinstalled with winget. `az acr build` didn't work on the trial; built and pushed with `dotnet publish -t:PublishContainer` and an `--expose-token` login, no Docker. `/t:` failed in Git Bash (MSYS path conversion), `-t:` works.
- **Namespace:** moved the app to `report`. The pod got `CreateContainerConfigError` because `sql-conn` existed only in `default`; secrets are per namespace. Also applied the wrong manifest once (`report-api-dev.yaml`) → `ContainerCreating` with `configmap "report-api-src" not found`.
- **Surprise:** AKS wasn't in the spoke. It ran in an AKS-managed VNet (`aks-vnet-34442549`, 10.224.0.0/12). Chose option B: endpoint in the spoke + peering + DNS links to both VNets (ADR-001).
- Private endpoint `sqlprivatelink` → `10.1.2.4`, status **Approved** (auto: we own the SQL server).
- Zone created through the portal's DNS integration landed in `rg-lab-spoke`, not the hub.
- Before closing the public door: pod `/dns` → `10.1.2.4`, `/reports` returned rows.
- Laptop `nslookup` now shows `labsqlprivate.privatelink.database.windows.net` in the chain but still answers `51.12.46.33` (split-horizon).
- After disabling public access: `Test-NetConnection 1433` can still be True (shared regional gateway); a login from the laptop is rejected: *"Public access is turned off for this server"*. App kept serving `/reports`.

## Proof
| Check | Before | After |
|---|---|---|
| Pod `/dns` | 51.12.46.33 | **10.1.2.4** |
| Pod `/reports` | rows | **rows** (no downtime) |
| Laptop `nslookup` | 51.12.46.33 | 51.12.46.33 via `privatelink` CNAME |
| Laptop login | works | **rejected (47073)** |
| `publicNetworkAccess` | Enabled | **Disabled** |

## Break-fix (break → symptom → diagnose → fix)
**INC-4471 (P1): "/reports failing, networking did some cleanup."** Score 6.5/8.
- **Break:** VNet link from `privatelink.database.windows.net` to the AKS VNet deleted.
- **Symptom:** latent. `/healthz` 200 (shallow, doesn't touch SQL) and `/reports` still worked through pooled SQL connections; fails on the next pod restart / scale-out. Pod `/dns` → public IP; public access disabled → login rejected.
- **Diagnose:** fresh lookup via `/dns` (public IP = DNS problem, not the endpoint) → list zone links → AKS VNet missing.
- **Fix:** re-add the link (auto-registration off) → `/dns` = 10.1.2.4.
- **Prevent:** CanNotDelete lock on the zone (covers child links); RBAC so only the platform team writes private DNS; IaC as source of truth with drift detection; Activity Log alert on `virtualNetworkLinks/delete`; a deep health check that resolves and queries SQL. Policy *audit* only detects.
- **Also found:** zone not linked to `vnet-spoke` (spoke VMs/jumpbox would resolve publicly); hub link not needed.

## Interview answers
Exam 2/7 (2026-10-24). Retry: Q4 what disabling public access does/doesn't fix, Q5 168.63.129.16, Q7 why "Allow Azure services" is flagged, Q1 all 4 pieces, Q2 3 causes, Q3 forwarding fix, Q6 order + why.

## What I learned
| # | Thing | In plain words | Why it matters in real life |
|---|---|---|---|
| 1 | Peering ≠ DNS | Peering is the road; the private DNS zone is the phone book. Each VNet needs its own zone link | The #1 private-endpoint outage: traffic path fine, name still public |
| 2 | Zone location | A private DNS zone is global; the RG is only ownership. Central zone in the hub, linked to every VNet | Duplicate zones per spoke give different answers depending on who asks |
| 3 | Rollout order | Private path first, prove from the pod, then close the public door | Disable first = outage until DNS is right |
| 4 | Endpoint approval | Auto-approved when you have the approve right on the target; Pending across teams/tenants | Vendor/partner connections wait for the owner's approval |
| 5 | 1433 open ≠ exposed | 51.x is the shared regional SQL gateway; it rejects at login | Prove with a login attempt, not a TCP test |
| 6 | Secrets per namespace | A pod reads Secrets only from its own namespace | Copies drift; use Key Vault CSI / External Secrets as one source |
| 7 | AKS VNet | Without `--vnet-subnet-id`, AKS creates its own VNet | Check `agentPoolProfiles[].vnetSubnetId` before designing private access |
| 8 | .NET 8 containers | SDK can build and push without Docker; images listen on 8080, run non-root | Service/probes must target 8080 |
| 9 | `--attach-acr` | AcrPull role on the ACR for the kubelet identity | No pull secrets; pods never log in to the registry |

## Gaps
- Skipped predictions and ran before stating a plan, several times.
- Endpoint approval: said it's about free IPs (it's permissions).
- Thought TCP 1433 = True after disabling meant the DB was still exposed.
- Hub vs spoke VNet naming mixed up ("spoke hub vnet").
- `--attach-acr`: said "pipeline to pods" (it's AcrPull on the kubelet identity).
- .NET 8 default port: said 80 (it's 8080).
