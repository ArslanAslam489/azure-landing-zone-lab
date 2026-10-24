#!/usr/bin/env bash
# Level 1 — Governance: management group, Azure Policy, RBAC
# Goal: put guardrails in place before anything is built, and prove control plane vs data plane.
set -euo pipefail
export MSYS_NO_PATHCONV=1
source ~/azlab.env

# =========================================================================
# 1a. Management group + org-wide policies
# =========================================================================
# A management group is a folder of subscriptions. Rules set here are inherited by every subscription inside.
az account management-group create --name mg-lab --display-name "Lab"

# Move our subscription from the Tenant Root Group into mg-lab.
az account management-group subscription add --name mg-lab --subscription "$SUB"

# Check: the subscription should now be listed under mg-lab.
az account management-group show --name mg-lab --expand --query "children[].displayName" -o tsv

# Save the MG's scope path for later commands.
echo 'export MG=/providers/Microsoft.Management/managementGroups/mg-lab' >> ~/azlab.env; source ~/azlab.env

# Policy 1: resources may only be created in Sweden Central or North Europe (data residency).
# (We assigned this in the portal; this is the CLI equivalent.)
LOCPOL=$(az policy definition list --query "[?displayName=='Allowed locations'].name" -o tsv)
az policy assignment create --name allowed-locations --policy "$LOCPOL" --scope "$MG" \
  --params '{"listOfAllowedLocations":{"value":["swedencentral","northeurope"]}}'

# Policy 2: every resource group must have an "owner" tag (cost and accountability).
# (Assigned in the portal.)
TAGPOL=$(az policy definition list --query "[?displayName=='Require a tag on resource groups'].name" -o tsv)
az policy assignment create --name rg-owner-tag --policy "$TAGPOL" --scope "$MG" \
  --params '{"tagName":{"value":"owner"}}'

# Check: both assignments exist. (We missed the tag policy the first time; this check would have caught it.)
az policy assignment list --scope "$MG" --query "[].{name:name, display:displayName}" -o table

# Policies need ~15 minutes to take effect. Then test them:
az group create -n rg-test -l "$LOC" || true                                   # DENIED: no owner tag
az group create -n rg-lab-hub   -l "$LOC" --tags owner=arslan env=lab           # allowed
az group create -n rg-lab-spoke -l "$LOC" --tags owner=arslan env=lab           # allowed
az storage account create -g rg-lab-hub -n "sttest$RANDOM" -l eastus || true   # DENIED: eastus not allowed

# Fix a wrong tag on an existing group (--tags replaces all tags).
az group update -n rg-lab-hub --tags owner=arslan env=lab

# List resource groups with their tags.
az group list --query "[].{name:name, tags:tags}" -o table

# =========================================================================
# 1b. No public IPs in the spoke
# =========================================================================
# Workloads in the spoke must never be exposed directly to the internet.
# Assigned on the spoke RG only, because the hub's Firewall needs a public IP.
# (Assigned in the portal.)
TYPEPOL=$(az policy definition list --query "[?displayName=='Not allowed resource types'].name" -o tsv)
az policy assignment create --name deny-public-ip --policy "$TYPEPOL" \
  --scope "/subscriptions/$SUB/resourceGroups/rg-lab-spoke" \
  --params '{"listOfResourceTypesNotAllowed":{"value":["Microsoft.Network/publicIPAddresses"]}}'

# Test: "pip" = Public IP address resource (it creates one; it is not a ping).
az network public-ip create -g rg-lab-spoke -n pip-test --sku Standard || true   # DENIED in spoke
az network public-ip create -g rg-lab-hub   -n pip-test --sku Standard           # allowed in hub
az network public-ip delete -g rg-lab-hub   -n pip-test                          # delete: public IPs cost money

# =========================================================================
# 1c. RBAC: control plane vs data plane
# =========================================================================
# Storage account for the test (unique name, saved for later levels).
ST=stlab$RANDOM; echo "export ST=$ST" >> ~/azlab.env
az storage account create -g rg-lab-spoke -n "$ST" -l "$LOC" --sku Standard_LRS --allow-blob-public-access false

# Every role has two lists: Actions (control plane, via ARM) and DataActions (data plane, via the service).
# Owner has all Actions ("*") but NO DataActions.
az role definition list -n "Owner" --query "[].{actions:permissions[0].actions, dataActions:permissions[0].dataActions}"
az role definition list -n "Storage Blob Data Contributor" --query "[].permissions[0].dataActions"

# Creating a container works as Owner: container create is an Action.
az storage container create --account-name "$ST" -n data --auth-mode login

# Uploading a blob as Owner with Entra login FAILS (403): writing data is a DataAction.
echo hi > t.txt
az storage blob upload --account-name "$ST" -c data -n t.txt -f t.txt --auth-mode login || true

# Note: the portal upload worked because the portal used the ACCESS KEY (Owner can list keys).
# A key bypasses RBAC completely, which is why security teams disable shared-key access.
az storage container list --account-name "$ST" --auth-mode key -o table   # works with the key, no data role

# Fix: give ourselves a data-plane role on this storage account only.
ME=$(az ad signed-in-user show --query id -o tsv); echo "export ME=$ME" >> ~/azlab.env
STID=$(az storage account show -g rg-lab-spoke -n "$ST" --query id -o tsv); echo "export STID=$STID" >> ~/azlab.env
az role assignment create --assignee "$ME" --role "Storage Blob Data Contributor" --scope "$STID"

# Role assignments take 2–5 minutes to apply. Then the upload works.
az storage blob upload --account-name "$ST" -c data -n t.txt -f t.txt --auth-mode login --overwrite

# Check: list my role assignments.
az role assignment list --assignee "$ME" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table

# =========================================================================
# Cleanup for this level
# =========================================================================
rm -f t.txt
az group delete -n rg-test --yes --no-wait 2>/dev/null || true   # only if it was created before the tag policy worked
