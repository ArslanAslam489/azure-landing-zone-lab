#!/usr/bin/env bash
# Delete all lab resource groups.
set -euo pipefail
for g in rg-lab-global rg-lab-dr rg-lab-aks rg-lab-spoke rg-lab-hub; do
  az group delete -n "$g" --yes --no-wait 2>/dev/null || true
done
az resource list -o table
