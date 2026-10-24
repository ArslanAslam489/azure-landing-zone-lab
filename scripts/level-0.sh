#!/usr/bin/env bash
# Level 0 — basics: subscription context, env file, providers, quota.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: stop /subscriptions/... being rewritten to C:/...
touch ~/azlab.env && source ~/azlab.env

az login --tenant "$TENANT_ID"      # MFA is enforced per tenant (AADSTS50076 without it)
az account show -o table
echo "export SUB=$(az account show --query id -o tsv)" >> ~/azlab.env
echo "export LOC=swedencentral LOC2=northeurope" >> ~/azlab.env
source ~/azlab.env

# Fresh subscription: resource providers are not registered yet.
for p in Microsoft.Compute Microsoft.Storage Microsoft.Network Microsoft.KeyVault \
         Microsoft.OperationalInsights Microsoft.Insights Microsoft.PolicyInsights; do
  az provider register -n "$p" --wait
done

az vm list-usage -l "$LOC" -o table | grep -i regional   # trial: 4 regional vCPUs
