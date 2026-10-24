#!/usr/bin/env bash
# Level 2 — Hub-spoke network, Azure Firewall, UDR
# Goal: a private VM in the spoke can reach the internet ONLY through a central firewall in the hub,
# and only to the websites we allow.
#
# Simple picture: the hub is the building's reception, the spoke is an office floor.
# Peering is the corridor between them. The firewall is the security guard at reception.
# The route table (UDR) is the sign on the office floor saying "all exits go via reception".
set -euo pipefail
export MSYS_NO_PATHCONV=1
source ~/azlab.env

# =========================================================================
# 2a. Networks: hub + spoke
# =========================================================================
# Hub: 10.0.0.0/16. The firewall must live in a subnet named exactly AzureFirewallSubnet.
# Firewall Basic also needs AzureFirewallManagementSubnet (Azure uses it to manage the firewall).
az network vnet create -g rg-lab-hub -n vnet-hub --address-prefixes 10.0.0.0/16 \
  --subnet-name AzureFirewallSubnet --subnet-prefixes 10.0.1.0/26
az network vnet subnet create -g rg-lab-hub --vnet-name vnet-hub -n AzureFirewallManagementSubnet --address-prefixes 10.0.2.0/26

# Spoke: 10.1.0.0/16. snet-vm for the VM, snet-pe reserved for private endpoints (used in Level 3).
az network vnet create -g rg-lab-spoke -n vnet-spoke --address-prefixes 10.1.0.0/16 \
  --subnet-name snet-vm --subnet-prefixes 10.1.1.0/24
az network vnet subnet create -g rg-lab-spoke --vnet-name vnet-spoke -n snet-pe --address-prefixes 10.1.2.0/24

# =========================================================================
# 2b. Peering (the corridor). Must be created from BOTH sides, or it stays "Initiated".
# =========================================================================
# --allow-forwarded-traffic: accept traffic the firewall forwards on behalf of someone else.
# Peering is NOT transitive: spoke A <-> hub <-> spoke B does not mean A can reach B without the firewall routing it.
HUBID=$(az network vnet show -g rg-lab-hub -n vnet-hub --query id -o tsv)
SPOKEID=$(az network vnet show -g rg-lab-spoke -n vnet-spoke --query id -o tsv)
az network vnet peering create -g rg-lab-hub -n hub-to-spoke --vnet-name vnet-hub --remote-vnet "$SPOKEID" --allow-vnet-access --allow-forwarded-traffic
az network vnet peering create -g rg-lab-spoke -n spoke-to-hub --vnet-name vnet-spoke --remote-vnet "$HUBID" --allow-vnet-access --allow-forwarded-traffic

# =========================================================================
# 2c. Private VM in the spoke
# =========================================================================
# First try WITH a public IP: our Level 1 policy (deny-public-ip on rg-lab-spoke) blocks it. That's the guardrail working.
# Then create it with no public IP and no NSG.
az vm create -g rg-lab-spoke -n vm-spoke --image Ubuntu2204 --size Standard_B1s \
  --vnet-name vnet-spoke --subnet snet-vm --public-ip-address "" --nsg "" --admin-username azureuser --generate-ssh-keys
# Size unavailable? Try Standard_B2ats_v2 or Standard_B2s.

# No SSH (no public IP). Run commands through Azure instead.
run() { az vm run-command invoke -g rg-lab-spoke -n vm-spoke --command-id RunShellScript --scripts "$1" --query "value[0].message" -o tsv; }

# The routes the VM's network card really uses. Before the UDR: 0.0.0.0/0 -> Internet.
az network nic show-effective-route-table -g rg-lab-spoke -n vm-spokeVMNic -o table

# =========================================================================
# 2d. Firewall Basic (created in the portal, ~15 min, ~$0.40/h)
# =========================================================================
# Portal: Firewall in rg-lab-hub, tier Basic, new policy fwp-lab, VNet vnet-hub,
# new public IP + management public IP. Note its PRIVATE IP.
FWIP=10.0.1.4   # the firewall's private IP from the portal

# =========================================================================
# 2e. Route table (UDR): send all spoke internet traffic to the firewall
# =========================================================================
# 0.0.0.0/0 = "anything not inside our networks". Next hop = the firewall's private IP.
az network route-table create -g rg-lab-spoke -n rt-spoke -l "$LOC"
az network route-table route create -g rg-lab-spoke --route-table-name rt-spoke -n default \
  --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address "$FWIP"
az network vnet subnet update -g rg-lab-spoke --vnet-name vnet-spoke -n snet-vm --route-table rt-spoke

# Effective routes again: 0.0.0.0/0 now points to the firewall (User source).
az network nic show-effective-route-table -g rg-lab-spoke -n vm-spokeVMNic -o table

# The firewall blocks everything by default: HTTP 470 = "denied by firewall".
run "curl -s -m 10 -o /dev/null -w '%{http_code}' https://www.google.com || echo BLOCKED"

# Portal: firewall policy fwp-lab -> Application rule: allow source 10.1.0.0/16 to the Ubuntu apt mirrors (FQDN), HTTP/HTTPS.
run "sudo apt-get update -qq && echo APT-OK"                                              # allowed -> works
run "curl -s -m 10 -o /dev/null -w '%{http_code}' https://www.google.com || echo BLOCKED"  # still 470

# =========================================================================
# Cleanup (done right after the level: the firewall is the expensive part)
# =========================================================================
# Portal: deleted the firewall and both its public IPs.
az vm deallocate -g rg-lab-spoke -n vm-spoke   # stopped and not billed for compute; frees vCPU quota for AKS
# Without the firewall the route points at nothing, so snet-vm has no internet. Remove it if the VM needs internet again:
# az network vnet subnet update -g rg-lab-spoke --vnet-name vnet-spoke -n snet-vm --remove routeTable
