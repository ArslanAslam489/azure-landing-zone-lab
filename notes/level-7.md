# Level 7 — Multi-region DR (in progress)

## Ticket
> **ARCH-310 — P1 — from CTO, after an outage drill**
> The customer report portal must survive a full Sweden Central outage: **RTO 1 h, RPO 5 min**. The DB stays private (SEC-2091).
> Design and prove DR to North Europe, with monthly cost and what we give up.

Script: [scripts/level-7.sh](../scripts/level-7.sh) · App: [app/report-api](../app/report-api)

## Plan (one hop at a time)
| Step | Add | Test | Status |
|---|---|---|---|
| 1 | Ingress controller (App Routing NGINX) | `EXTERNAL-IP` | ✅ |
| 2 | App v2 (portal page, `/info`) + ingress rule | `http://<LBIP>/` shows the portal | ✅ |
| 3 | Global entry in front of the ingress | global URL shows the portal | ⛔ Front Door blocked on trial → Traffic Manager next |
| 4 | Lock the origin to the global entry only | direct IP fails, global URL works | — |
| 5 | Outage drill on the single region (measure current RTO) | portal goes red | — |
| 6 | North Europe stack + SQL failover group + private DNS | both regions healthy | — |
| 7 | Failover drill, fail back | RTO/RPO measured | — |

## What happened
- **Ingress instead of one LoadBalancer per Service:** a real cluster runs many services of one product; one entry, host/path routing, shared TLS.
- **NGINX Pending → browser timeout.** `Insufficient cpu`: node at 88% CPU *requested* (gatekeeper, CoreDNS, metrics-server, workload-identity webhook…), NGINX asks 500m. Azure LB probe saw no ready NGINX → dropped connections silently.
- Scale to 2 nodes failed: `ErrCode_InsufficientVCPUQuota` (regional quota 4/4 on the trial).
- Lab fix: NGINX 1 replica + Azure Policy add-on disabled (~360m freed). Re-enable after the level.
- NGINX then answered `404 ... nginx`: the Ingress rule had never been applied. Applied → 200.
- App v2 push failed with `CONTAINER1016`: `~/.docker/config.json` held an ACR token from 13:07 that had expired. Rewrote it with a fresh token.
- Rolling update with 1 replica: no downtime (maxSurge 1, maxUnavailable 0, readiness gates traffic).
- `Microsoft.Cdn` provider registered, `rg-lab-global` in North Europe; **Front Door forbidden on Free Trial**.

## Concepts
- **Scheduler = requests, not usage.** A node "at 30% CPU" can be full.
- **LB health probe:** no ready backend → TCP timeout, not an HTTP error.
- **NGINX 404 vs app 404:** the body/server tells you which hop answered.
- **Global vs regional:** Front Door / Traffic Manager are global; Application Gateway and the ingress LB are regional and die with the region.
- **RG location** = where metadata lives. Keep the global RG outside the primary region so you can still manage it during an outage.
- **Front Door vs Traffic Manager:** anycast reverse proxy (seconds, TLS, WAF) vs DNS answer (TTL-bound failover, no proxy).

## Interview answers
_Pending (10 questions in the Level 7 lab ticket)._

## Gaps
- Skipped the rollout prediction (maxSurge/maxUnavailable).
- Picked a fix without stating the trade-off.
- DR terms (RTO/RPO, PITR/STR/LTR, failover group listener) still to study.
