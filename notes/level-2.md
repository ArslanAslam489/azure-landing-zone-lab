# Level 2 — Hub-spoke network, Azure Firewall, UDR

Script: [scripts/level-2.sh](../scripts/level-2.sh)

## What happened
- Built hub (10.0.0.0/16) and spoke (10.1.0.0/16) VNets, peered both ways.
- VM with a public IP was **denied** by the `deny-public-ip` policy on rg-lab-spoke (Level 1 guardrail working). Created it private.
- Added UDR `0.0.0.0/0 → Firewall private IP` on snet-vm. Effective routes changed from `Internet` to `VirtualAppliance`.
- Firewall Basic denied everything by default: **HTTP 470**.
- Added an FQDN application rule for the apt mirrors: `apt update` worked, google.com still 470.
- Cleanup: firewall + both public IPs deleted, VM deallocated.

## Concepts
- Hub-spoke: shared services (firewall, DNS, VPN) once in the hub; workloads in spokes. Peering is not transitive.
- UDR overrides Azure's default routes. Next hop "VirtualAppliance" = send to this IP (the firewall).
- The firewall's public IP becomes our single outbound IP, so partners can allow-list it.

## Interview answers
Exam score 2/6. Retry these:
- Firewall vs NSG
- Firewall vs NAT Gateway
- Asymmetric routing

## Gaps
- Firewall vs NSG (0)
- Firewall vs NAT Gateway (0)
- Asymmetric routing
- Mixed up inbound vs outbound direction.
