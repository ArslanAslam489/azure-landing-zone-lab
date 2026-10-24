#!/usr/bin/env bash
# Level 3 — Private endpoint + private DNS (ticket SEC-2091)
# Goal: an app on AKS reads from Azure SQL. Today it goes over the PUBLIC internet.
# Make the database reachable only privately from our network, close the public door, zero downtime.
#
# Simple picture: the database is a shop with its front door on a busy street (public endpoint).
# Our app lives in our own building (the VNet) and walks out onto the street to reach it.
# The fix: build a private corridor from our building into the shop (private endpoint), then lock the street door.
#
# Part 1 below builds the "before" world. Part 2 (the fix) is added after we design and run it.
set -euo pipefail
export MSYS_NO_PATHCONV=1
source ~/azlab.env

# =========================================================================
# 0. Pre-checks (the ones people skip)
# =========================================================================
# Switch on the Azure services we need. Safe to run again.
az provider register -n Microsoft.ContainerService
az provider register -n Microsoft.ContainerRegistry
az provider register -n Microsoft.Sql

# The spoke network must have room for the AKS subnet 10.1.8.0/22 (e.g. 10.1.0.0/16 contains it).
az network vnet show -g rg-lab-spoke -n vnet-spoke --query addressSpace.addressPrefixes -o tsv

# CPU quota: a trial gives ~4 vCPUs per region. The AKS node needs 2; keep the Level 2 VM deallocated.
az vm list-usage -l "$LOC" --query "[?name.value=='cores' || name.value=='standardBSFamily'].{name:name.localizedValue, used:currentValue, limit:limit}" -o table

# =========================================================================
# 1. Database: Azure SQL Database, SQL login (created in the portal)
# =========================================================================
# Lives in rg-lab-spoke, next to the spoke network, because the private endpoint will go there.
# Chose Azure SQL Database (serverless, free offer), not Managed Instance: MI is expensive, needs its own subnet, takes hours.
# SQL and SQLPASS must be in ~/azlab.env (see lab.env.example).
: "${AKS:?add AKS to ~/azlab.env}" "${SQL:?add SQL to ~/azlab.env}" "${SQLPASS:?add SQLPASS to ~/azlab.env}"

# Today the server is public. This is what the pentester found.
az sql server show -g rg-lab-spoke -n "$SQL" --query "{name:name, public:publicNetworkAccess, fqdn:fullyQualifiedDomainName}" -o table
az sql db list -g rg-lab-spoke -s "$SQL" --query "[].name" -o tsv     # must include appdb

# "Allow Azure services" (0.0.0.0) lets ANY Azure resource in, even other customers'. Security flagged it,
# but it's how the app connects today, so it stays until the private path works.
az sql server firewall-rule create -g rg-lab-spoke -s "$SQL" -n AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0

# =========================================================================
# 2. Kubernetes cluster (AKS) inside the spoke
# =========================================================================
# A separate room (subnet) in the spoke just for Kubernetes nodes.
az network vnet subnet create -g rg-lab-spoke --vnet-name vnet-spoke -n snet-aks --address-prefixes 10.1.8.0/22
AKSSUBNET=$(az network vnet subnet show -g rg-lab-spoke --vnet-name vnet-spoke -n snet-aks --query id -o tsv)

# Every RG needs an owner tag (our Level 1 policy), or Azure refuses it.
az group create -n rg-lab-aks -l "$LOC" --tags owner=arslan env=lab

# ~8 minutes. In plain words:
#   --tier free                    no paid uptime guarantee, fine for a lab
#   --node-resource-group          AKS makes a second RG for its own VMs/disks; we pick the name
#   --node-count 1, B2s            one small machine (2 vCPU, 4 GB)
#   --network-plugin azure overlay nodes get IPs from our subnet, pods from a separate private range
#   --vnet-subnet-id               put the node in OUR spoke, so it can use the private corridor later
# Size not available? Use Standard_B2s_v2 or Standard_B2als_v2.
az aks create -g rg-lab-aks -n "$AKS" -l "$LOC" --tier free --node-resource-group rg-lab-aks-nodes \
  --node-count 1 --node-vm-size Standard_B2s --tags owner=arslan env=lab \
  --network-plugin azure --network-plugin-mode overlay --vnet-subnet-id "$AKSSUBNET" --generate-ssh-keys

# Run kubectl INSIDE Azure, so no kubectl on the laptop. (Also saved in ~/azlab.env so new terminals have it.)
k() { az aks command invoke -g rg-lab-aks -n "$AKS" --command "$1" ${2:+--file $2} --query logs -o tsv; }
k "kubectl get nodes -o wide"     # INTERNAL-IP should come from snet-aks (10.1.8.0/22)

# =========================================================================
# 3. The app's database password, how the dev team did it
# =========================================================================
# A Kubernetes Secret is a labelled envelope the app opens at startup. Only base64, not encrypted:
# anyone who can read secrets in the namespace can read the password. (Ticket SEC-2092 removes it.)
# Single quotes so passwords with ! or $ don't break the command.
k "kubectl create secret generic sql-conn \
  --from-literal=SQL_SERVER=$SQL.database.windows.net \
  --from-literal=SQL_DB=appdb \
  --from-literal=SQL_USER=sqladmin \
  --from-literal=SQL_PASSWORD='$SQLPASS'"

# =========================================================================
# 4. Build and run the report API (app/report-api, .NET 8)
# =========================================================================
# ACR = a private shelf for app images. `az acr build` sends our code to Azure and builds it there: no Docker on the laptop.
cd "$(dirname "$0")/../app/report-api"
if [ -z "${ACR:-}" ]; then ACR=acrlab$RANDOM; echo "export ACR=$ACR" >> ~/azlab.env; fi
az acr create -g rg-lab-aks -n "$ACR" --sku Basic -l "$LOC" --tags owner=arslan env=lab
az acr build -r "$ACR" -t report-api:v1 .

# Give the cluster a key to pull from the shelf (AcrPull role for the node identity).
az aks update -g rg-lab-aks -n "$AKS" --attach-acr "$ACR"

sed "s/<ACR>/$ACR/" report-api.yaml > report-api.rendered.yaml
k "kubectl apply -f report-api.rendered.yaml" report-api.rendered.yaml
k "kubectl get pods -o wide"

# =========================================================================
# 5. Baseline proof: the "before" state (save these outputs)
# =========================================================================
# Heartbeat every 20s: "report OK" or "report FAILED: <reason>". This is our downtime alarm for the whole ticket.
# First try may fail ~1 min while serverless SQL wakes from auto-pause.
k "kubectl logs deploy/report-api --tail=3"

# Call the API from inside the cluster (the Service has no public IP). /dns = what the SQL name becomes inside the pod.
k "kubectl delete pod curl --ignore-not-found; kubectl run curl --image=curlimages/curl --restart=Never -- -s http://report-api/reports http://report-api/dns; kubectl wait --for=jsonpath={.status.phase}=Succeeded pod/curl --timeout=60s; kubectl logs curl"

# From the laptop (= the internet, where the pentester stood).
nslookup "$SQL.database.windows.net"
# PowerShell: Test-NetConnection <sql>.database.windows.net -Port 1433   -> today TcpTestSucceeded = True

# =========================================================================
# Part 2 — the fix (added after design + run)
# =========================================================================

# =========================================================================
# End of session
# =========================================================================
# az aks stop -g rg-lab-aks -n "$AKS"     # node off, everything kept; `az aks start` next time
# SQL auto-pauses after 60 min idle. ACR Basic ~$0.17/day: delete at the end of Level 3.
