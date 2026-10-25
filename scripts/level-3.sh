#!/usr/bin/env bash
# Level 3 — Private endpoint + private DNS (ticket SEC-2091)
# Goal: an app on AKS reads from Azure SQL. Today it goes over the PUBLIC internet.
# Make the database reachable only privately from our network, close the public door, zero downtime.
#
# Simple picture: the database is a shop with its front door on a busy street (public endpoint).
# Our app lives in our own building (the VNet) and walks out onto the street to reach it.
# The fix: build a private corridor from our building into the shop (private endpoint), then lock the street door.
#
# Part 1 builds the "before" world. Part 2 is the fix, in the zero-downtime order.
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
# but it's how the app connects today, so it stays until the private path works (deleted in step 10).
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
# Without --vnet-subnet-id, AKS builds its own VNet (aks-vnet-xxxx, 10.224.0.0/12) in the node RG.
# That happened in our run; Part 2 handles both cases (see ADR-001).
az aks create -g rg-lab-aks -n "$AKS" -l "$LOC" --tier free --node-resource-group rg-lab-aks-nodes \
  --node-count 1 --node-vm-size Standard_B2s --tags owner=arslan env=lab \
  --network-plugin azure --network-plugin-mode overlay --vnet-subnet-id "$AKSSUBNET" --generate-ssh-keys

# Run kubectl INSIDE Azure, so no kubectl on the laptop. (Also saved in ~/azlab.env so new terminals have it.)
k() { az aks command invoke -g rg-lab-aks -n "$AKS" --command "$1" ${2:+--file $2} --query logs -o tsv; }
k "kubectl get nodes -o wide"

# The app gets its own namespace: a scope for RBAC, quotas, network policies, and one-command cleanup.
NS=report
k "kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -"

# =========================================================================
# 3. The app's database password, how the dev team did it
# =========================================================================
# A Kubernetes Secret is a labelled envelope the app opens at startup. Only base64, not encrypted:
# anyone who can read secrets in the namespace can read the password. (Ticket SEC-2092 removes it.)
# Secrets are per namespace: a pod in "report" can't read one in "default" (CreateContainerConfigError).
# Single quotes so passwords with ! or $ don't break the command.
k "kubectl create secret generic sql-conn -n $NS \
  --from-literal=SQL_SERVER=$SQL.database.windows.net \
  --from-literal=SQL_DB=appdb \
  --from-literal=SQL_USER=sqladmin \
  --from-literal=SQL_PASSWORD='$SQLPASS'"

# =========================================================================
# 4. Build and run the report API (app/report-api, .NET 8)
# =========================================================================
# ACR = a private shelf for app images.
cd "$(dirname "$0")/../app/report-api"
if [ -z "${ACR:-}" ]; then ACR=acrlab$RANDOM; echo "export ACR=$ACR" >> ~/azlab.env; fi
az acr create -g rg-lab-aks -n "$ACR" --sku Basic -l "$LOC" --tags owner=arslan env=lab

# `az acr build` (build in Azure) is blocked on free-trial subscriptions (ACR Tasks), and there's no Docker on the laptop.
# The .NET 8 SDK builds the image itself and pushes it straight to ACR. It ignores the Dockerfile:
# base image is picked from the project (web app on net8.0 -> mcr.microsoft.com/dotnet/aspnet:8.0), listens on 8080, non-root.
# Registry login without Docker: a short-lived token (~3 h) as the password, the all-zero GUID as the user.
TOKEN=$(az acr login -n "$ACR" --expose-token --query accessToken -o tsv)
export DOTNET_CONTAINER_REGISTRY_UNAME=00000000-0000-0000-0000-000000000000 DOTNET_CONTAINER_REGISTRY_PWD="$TOKEN"
export SDK_CONTAINER_REGISTRY_UNAME=$DOTNET_CONTAINER_REGISTRY_UNAME SDK_CONTAINER_REGISTRY_PWD="$TOKEN"
# -t: not /t: — Git Bash rewrites arguments starting with / as paths.
dotnet publish -c Release -t:PublishContainer \
  -p ContainerRegistry="$ACR.azurecr.io" -p ContainerRepository=report-api -p ContainerImageTag=v1
az acr repository show-tags -n "$ACR" --repository report-api -o table

# Give the cluster a key to pull from the shelf: AcrPull role on the ACR for the kubelet (node) identity.
# Pods never log in to the registry; the kubelet pulls the image.
az aks update -g rg-lab-aks -n "$AKS" --attach-acr "$ACR"

sed "s/<ACR>/$ACR/" report-api.yaml > report-api.rendered.yaml
k "kubectl apply -n $NS -f report-api.rendered.yaml" report-api.rendered.yaml
k "kubectl get pods -n $NS -o wide"     # expect 1/1 Running: readiness probe on /healthz:8080 passes

# =========================================================================
# 5. Baseline proof: the "before" state (save these outputs)
# =========================================================================
# First try may fail ~1 min while serverless SQL wakes from auto-pause.
k "kubectl logs deploy/report-api -n $NS --tail=3"

# Call the API from inside the cluster (the Service has no public IP).
# /reports runs a real SQL query; /dns = what the SQL name becomes inside the pod. Today: a public IP.
curlpod() { k "kubectl delete pod curl -n $NS --ignore-not-found; kubectl run curl -n $NS --image=curlimages/curl --restart=Never -- -s $1; kubectl wait -n $NS --for=jsonpath={.status.phase}=Succeeded pod/curl --timeout=60s; kubectl logs -n $NS curl"; }
curlpod "http://report-api/reports http://report-api/dns"

# From the laptop (= the internet, where the pentester stood). Today: public IP, no "privatelink" in the chain.
nslookup "$SQL.database.windows.net"
# PowerShell: Test-NetConnection <sql>.database.windows.net -Port 1433   -> today TcpTestSucceeded = True

# =========================================================================
# Part 2 — the fix (SEC-2091)
# =========================================================================
# Zero-downtime order: build the private path while the public door is still open, prove the app uses it,
# and only then close the public door. Close it first and the pod's DNS still points at the public IP -> outage.
#
# The 4 pieces of a working private endpoint:
#   1. private endpoint (a NIC with a private IP in our subnet)
#   2. private DNS zone privatelink.database.windows.net (the phone book)
#   3. VNet links (which VNets may read the phone book)
#   4. DNS zone group (writes and maintains the A record name -> private IP)

# Where does AKS really live? If the cluster was created without --vnet-subnet-id, its nodes sit in
# an AKS-managed VNet in the node RG, not in the spoke.
AKSNODESUBNET=$(az aks show -g rg-lab-aks -n "$AKS" --query "agentPoolProfiles[0].vnetSubnetId" -o tsv)
if [ -n "$AKSNODESUBNET" ]; then AKSVNETID=${AKSNODESUBNET%/subnets/*}
else AKSVNETID=$(az network vnet list -g rg-lab-aks-nodes --query "[0].id" -o tsv); fi
SPOKEID=$(az network vnet show -g rg-lab-spoke -n vnet-spoke --query id -o tsv)
echo "AKS nodes are in: $AKSVNETID"

# =========================================================================
# 6. Private endpoint in the spoke (snet-pe, made in Level 2)
# =========================================================================
# The endpoint belongs to the workload, so it lives with the SQL server (same RG, owner, lifecycle).
# Dynamic IP: it stays the same for the endpoint's whole life; the zone group keeps DNS in sync.
# Auto-approved because we have the approve right on the SQL server. Another team/tenant would see "Pending".
PE=${PE:-pe-$SQL}
SQLID=$(az sql server show -g rg-lab-spoke -n "$SQL" --query id -o tsv)
az network private-endpoint create -g rg-lab-spoke -n "$PE" -l "$LOC" \
  --vnet-name vnet-spoke --subnet snet-pe \
  --private-connection-resource-id "$SQLID" --group-id sqlServer --connection-name "$PE-conn"
az network private-endpoint show -g rg-lab-spoke -n "$PE" \
  --query "{ip:customDnsConfigs[0].ipAddresses[0], state:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" -o table
# expect: 10.1.2.4, Approved

# =========================================================================
# 7. Peering: AKS VNet <-> spoke (only when AKS is NOT in the spoke)
# =========================================================================
# Peering is the road for packets. It does NOT share DNS: each VNet still needs its own zone link (step 8).
# Changing a VNet AKS owns (in the node RG) is a lab trade-off; the proper fix is AKS in the spoke (ADR-001).
if [ "$AKSVNETID" != "$SPOKEID" ]; then
  AKSVNETRG=$(echo "$AKSVNETID" | cut -d/ -f5); AKSVNET=${AKSVNETID##*/}
  az network vnet peering create -g "$AKSVNETRG" -n aks-to-spoke --vnet-name "$AKSVNET" --remote-vnet "$SPOKEID" --allow-vnet-access
  az network vnet peering create -g rg-lab-spoke -n spoke-to-aks --vnet-name vnet-spoke --remote-vnet "$AKSVNETID" --allow-vnet-access
  az network vnet peering list -g rg-lab-spoke --vnet-name vnet-spoke --query "[].{name:name, state:peeringState, sync:peeringSyncLevel}" -o table
fi

# =========================================================================
# 8. Private DNS zone + VNet links
# =========================================================================
# The zone is global, not inside a VNet. The RG is only ownership: central (hub) in the enterprise pattern,
# one zone linked to every VNet. One zone per spoke = duplicate zones and answers that depend on who asks.
# Our run created it in rg-lab-spoke via the portal's "Integrate with private DNS zone"; set DNSRG=rg-lab-spoke for that env.
# Link only VNets whose clients must resolve SQL privately. Auto-registration off: that's for VM hostnames.
DNSRG=${DNSRG:-rg-lab-hub}
ZONE=privatelink.database.windows.net
az network private-dns zone create -g "$DNSRG" -n "$ZONE"
az network private-dns link vnet create -g "$DNSRG" -z "$ZONE" -n link-spoke -v "$SPOKEID" -e false
if [ "$AKSVNETID" != "$SPOKEID" ]; then
  az network private-dns link vnet create -g "$DNSRG" -z "$ZONE" -n link-aks -v "$AKSVNETID" -e false
fi

# Predict before step 9: the zone is linked but empty. What does the pod's /dns return now?

# =========================================================================
# 9. Zone group: the A record <sql> -> 10.1.2.4, maintained by Azure
# =========================================================================
ZONEID=$(az network private-dns zone show -g "$DNSRG" -n "$ZONE" --query id -o tsv)
az network private-endpoint dns-zone-group create -g rg-lab-spoke --endpoint-name "$PE" -n default \
  --private-dns-zone "$ZONEID" --zone-name sql
az network private-dns record-set a list -g "$DNSRG" -z "$ZONE" --query "[].{name:name, ip:aRecords[0].ipv4Address}" -o table

# Gate: don't touch the public door until the pod resolves privately AND the app still reads data.
# Pod -> CoreDNS -> 168.63.129.16 (Azure DNS), which answers from zones linked to the node's VNet.
OUT=$(curlpod "http://report-api/dns http://report-api/reports")
echo "$OUT"
echo "$OUT" | grep -q '"10\.1\.2\.' || { echo "STOP: SQL still resolves publicly inside AKS. Check the link to the AKS VNet and the zone group."; exit 1; }
echo "$OUT" | grep -q '"title"'    || { echo "STOP: DNS is private but the query failed. Check peering and the PE state."; exit 1; }

# =========================================================================
# 10. Close the public door
# =========================================================================
# Firewall rule first: it's ignored while public access is disabled, but if someone re-enables public access
# it would open the server to all of Azure again. Then disable public network access.
az sql server firewall-rule delete -g rg-lab-spoke -s "$SQL" -n AllowAzureServices
az sql server update -g rg-lab-spoke -n "$SQL" --enable-public-network false
az sql server show -g rg-lab-spoke -n "$SQL" --query publicNetworkAccess -o tsv     # expect: Disabled
az sql server firewall-rule list -g rg-lab-spoke -s "$SQL" -o table                 # expect: empty

# =========================================================================
# 11. After proof (compare with step 5)
# =========================================================================
# Inside AKS: private IP, data still flows (zero downtime).
curlpod "http://report-api/dns http://report-api/reports"
k "kubectl logs deploy/report-api -n $NS --tail=5"

# Laptop: split-horizon DNS. Public DNS still answers 51.x (the chain now shows <sql>.privatelink...),
# and Test-NetConnection 1433 may still say True: 51.x is the SHARED regional SQL gateway, not our server.
# The real proof is a login attempt from the laptop (portal Query editor or sqlcmd):
#   "Public access is turned off for this server" (error 47073).
nslookup "$SQL.database.windows.net"

# =========================================================================
# End of session
# =========================================================================
# az aks stop -g rg-lab-aks -n "$AKS"     # node off, everything kept; `az aks start` next time
# SQL auto-pauses after 60 min idle. ACR Basic ~$0.17/day: delete at the end of Level 3.
