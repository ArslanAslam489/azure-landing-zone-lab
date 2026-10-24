# Azure Landing Zone Lab

Hands-on build of a mini Azure landing zone, a private workload, AKS, and multi-region DR, built with Azure CLI.
Each level follows: **predict → run → break → fix → explain**.

## Architecture
<!-- add diagrams/architecture.png after Level 4 -->

## Levels
| # | Topic | Script | Notes |
|---|---|---|---|
| 0 | Basics: tenant, subscription, control vs data plane | [level-0](scripts/level-0.sh) | [notes](notes/level-0.md) |
| 1 | Governance: management groups, Policy, RBAC | [level-1](scripts/level-1.sh) | [notes](notes/level-1.md) |
| 2 | Hub-spoke network, Azure Firewall, UDR | [level-2](scripts/level-2.sh) | [notes](notes/level-2.md) |
| 3 | Private endpoint + private DNS | [level-3](scripts/level-3.sh) | [notes](notes/level-3.md) |
| 4 | Security & observability (auditor view) | [level-4](scripts/level-4.sh) | [notes](notes/level-4.md) |
| 5 | App Service → Azure SQL over private endpoint, managed identity | [level-5](scripts/level-5.sh) | [notes](notes/level-5.md) |
| 6 | AKS: workload identity, HPA, KEDA, failures | [level-6](scripts/level-6.sh) | [notes](notes/level-6.md) |
| 7 | Multi-region DR: Front Door, SQL failover group, Backup, ASR | [level-7](scripts/level-7.sh) | [notes](notes/level-7.md) |
| 8 | Architecture walkthrough + ADRs | — | [adr](adr/) |

## Key decisions
<!-- one line per ADR: decision + why + cost -->

## How to run
```bash
export MSYS_NO_PATHCONV=1      # Git Bash on Windows
cp lab.env.example ~/azlab.env  # fill in your values; never commit it
source ~/azlab.env
```
Each script deletes nothing by itself; see `scripts/cleanup.sh`.

## Cost
Built on a free-trial subscription. Delete resources after each session.

## Author
Arslan Aslam, Cloud Solution Architect · arslanaslam489@gmail.com
