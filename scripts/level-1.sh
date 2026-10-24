#!/usr/bin/env bash
# Level 1 — governance: management group, Policy, RBAC (control vs data plane).
set -euo pipefail
export MSYS_NO_PATHCONV=1
source ~/azlab.env

# 1a. Management group + org-wide policies (assigned at the MG, inherited by every subscription)
az account management-group create --name mg-lab --display-name "Lab"
az account management-group subscription add --name mg-lab --subscription "$SUB"
echo 'export MG=/providers/Microsoft.Management/managementGroups/mg-lab' >> ~/azlab.env; source ~/azlab.env

# done via portal; CLI equivalent:
LOCPOL=$(az policy definition list --query "[?displayName=='Allowed locations'].name" -o tsv)
az policy assignment create --name allowed-locations --policy "$LOCPOL" --scope "$MG" \
  --params '{"listOfAllowedLocations":{"value":["swedencentral","northeurope"]}}'
TAGPOL=$(az policy definition list --query "[?displayName=='Require a tag on resource groups'].name" -o tsv)
az policy assignment create --name rg-owner-tag --policy "$TAGPOL" --scope "$MG" \
  --params '{"tagName":{"value":"owner"}}'

# Tests (after ~15 min propagation)
az group create -n rg-test -l "$LOC" || true                                  # denied: no owner tag
az group create -n rg-lab-hub   -l "$LOC" --tags owner=arslan env=lab
az group create -n rg-lab-spoke -l "$LOC" --tags owner=arslan env=lab
az storage account create -g rg-lab-hub -n "sttest$RANDOM" -l eastus || true  # denied: location

# 1b. Deny public IPs in the spoke only (hub Firewall needs one)
# done via portal; CLI equivalent:
TYPEPOL=$(az policy definition list --query "[?displayName=='Not allowed resource types'].name" -o tsv)
az policy assignment create --name deny-public-ip --policy "$TYPEPOL" \
  --scope "/subscriptions/$SUB/resourceGroups/rg-lab-spoke" \
  --params '{"listOfResourceTypesNotAllowed":{"value":["Microsoft.Network/publicIPAddresses"]}}'
az network public-ip create -g rg-lab-spoke -n pip-test --sku Standard || true   # denied
az network public-ip create -g rg-lab-hub   -n pip-test --sku Standard           # allowed
az network public-ip delete -g rg-lab-hub   -n pip-test

# 1c. RBAC: Owner (control plane) vs data plane
ST=stlab$RANDOM; echo "export ST=$ST" >> ~/azlab.env
az storage account create -g rg-lab-spoke -n "$ST" -l "$LOC" --sku Standard_LRS --allow-blob-public-access false
az storage container create --account-name "$ST" -n data --auth-mode login   # works: containers/write is an Action
echo hi > t.txt
az storage blob upload --account-name "$ST" -c data -n t.txt -f t.txt --auth-mode login || true  # 403: no DataAction

ME=$(az ad signed-in-user show --query id -o tsv); echo "export ME=$ME" >> ~/azlab.env
STID=$(az storage account show -g rg-lab-spoke -n "$ST" --query id -o tsv); echo "export STID=$STID" >> ~/azlab.env
az role assignment create --assignee "$ME" --role "Storage Blob Data Contributor" --scope "$STID"
# wait 2-5 min for RBAC propagation
az storage blob upload --account-name "$ST" -c data -n t.txt -f t.txt --auth-mode login --overwrite
