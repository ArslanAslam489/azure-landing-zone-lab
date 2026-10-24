#!/usr/bin/env bash
# Level 0 — Basics
# Goal: log in to the right tenant, pick the subscription, save settings, and check what we're allowed to build.
set -euo pipefail

# Git Bash on Windows rewrites paths like /subscriptions/... into C:/... — this stops that.
export MSYS_NO_PATHCONV=1

# Our settings file (subscription, region, names). It stays on this PC and is never committed.
touch ~/azlab.env && source ~/azlab.env

# --- Log in -------------------------------------------------------------
# Plain "az login" found no subscriptions because each tenant requires MFA.
# Logging in to the tenant directly triggers the MFA prompt.
# Note: --tenant needs the TENANT ID, not the subscription ID.
az login --tenant "$TENANT_ID"

# Show every subscription this account can see, then make ours the default.
az account list -o table --all
az account set --subscription "Azure subscription 1"
az account show -o table

# --- Save settings for later levels -------------------------------------
echo "export SUB=$(az account show --query id -o tsv)" >> ~/azlab.env
echo "export LOC=swedencentral LOC2=northeurope" >> ~/azlab.env   # main region + DR region
source ~/azlab.env

# --- Register resource providers ----------------------------------------
# A fresh subscription can't use a service until its provider is registered.
# Example: Microsoft.Compute builds VMs, Microsoft.Storage builds storage accounts.
for p in Microsoft.Compute Microsoft.Storage Microsoft.Network Microsoft.KeyVault \
         Microsoft.OperationalInsights Microsoft.Insights Microsoft.PolicyInsights; do
  az provider register -n "$p" --wait
done
az provider show -n Microsoft.Compute --query registrationState -o tsv   # expect: Registered

# --- Check quota ---------------------------------------------------------
# How many vCPUs we may run in this region. Free trial = 4.
az vm list-usage -l "$LOC" -o table | grep -i regional

# --- See ARM in action (optional) ---------------------------------------
# Every az command is a REST call to ARM (management.azure.com).
az group list --debug 2>&1 | grep -i "request url" || true

# --- Troubleshooting we hit ----------------------------------------------
# "No module named 'msrestazure'" on az account management-group:
# an old 'subscription' CLI extension overrides 'az account'. Remove it:
#   az extension remove -n subscription
