#!/usr/bin/env bash
# Level 7 — Multi-region DR (in progress). Commands actually run so far. Values come from ~/azlab.env, no IDs here.
# Goal (ticket ARCH-310): the report portal survives a Sweden Central outage, RTO 1 h, RPO 5 min, SQL stays private.
#
# Simple picture: today the shop has one branch (Sweden Central). If that branch burns down, customers find a locked door.
# DR = a second branch (North Europe) with a copy of the books, and a receptionist who sends customers to whichever branch is open.
#
# Step by step, one hop at a time:
#   1. ingress controller -> 2. app v2 + ingress rule -> 3. global entry (Front Door / Traffic Manager) -> 4. lock origin to it
set -euo pipefail
export MSYS_NO_PATHCONV=1
source ~/azlab.env
: "${AKS:?add AKS to ~/azlab.env}" "${ACR:?add ACR to ~/azlab.env}"
cd "$(dirname "$0")/../app/report-api"

# =========================================================================
# 1. Ingress controller (App Routing add-on = Microsoft-managed NGINX)
# =========================================================================
# One public entry for many services of one product, instead of one public LoadBalancer per Service.
# report-api stays ClusterIP. The add-on creates Service "nginx" (type LoadBalancer) = the public IP.
az aks approuting enable -g rg-lab-aks -n "$AKS"
kubectl get svc nginx -n app-routing-system        # EXTERNAL-IP = origin for the global entry

# What broke: NGINX pods Pending, "0/1 nodes are available: 1 Insufficient cpu".
# The scheduler counts REQUESTS, not usage: the single D2as_v5 node was at 88% requested, NGINX asks 500m.
# The Azure LB health probe found no ready NGINX -> no healthy backend -> browser TIMEOUT (not an error page).
kubectl describe node | grep -A8 "Allocated resources"

# Fix A (scale to 2 nodes) failed: regional vCPU quota 4/4 on the trial.
#   az aks nodepool scale -g rg-lab-aks --cluster-name "$AKS" -n agentpool --node-count 2  -> ErrCode_InsufficientVCPUQuota
# Lab fix: 1 NGINX replica, and turn off the Azure Policy add-on (gatekeeper, ~360m requested).
# Trade-off: no in-cluster policy enforcement until re-enabled; subscription/MG policies still apply.
# Production answer: 2+ nodes, 2+ ingress replicas across zones.
kubectl patch nginxingresscontroller default --type merge -p '{"spec":{"scaling":{"minReplicas":1,"maxReplicas":1}}}'
az aks disable-addons -g rg-lab-aks -n "$AKS" -a azure-policy
# Re-enable after the level: az aks enable-addons -g rg-lab-aks -n "$AKS" -a azure-policy

# =========================================================================
# 2. App v2 (portal page at "/", /info shows region + pod) and the ingress rule
# =========================================================================
# Registry login without Docker. The SDK reads ~/.docker/config.json if it exists: a token saved there
# expires after ~3 h (CONTAINER1016 on push). Rewrite it with a fresh token before every push.
TOKEN=$(az acr login -n "$ACR" --expose-token --query accessToken -o tsv)
AUTH=$(printf '00000000-0000-0000-0000-000000000000:%s' "$TOKEN" | base64 -w0)
mkdir -p ~/.docker && echo "{\"auths\":{\"$ACR.azurecr.io\":{\"auth\":\"$AUTH\"}}}" > ~/.docker/config.json
dotnet publish -c Release -t:PublishContainer \
  -p ContainerRegistry="$ACR.azurecr.io" -p ContainerRepository=report-api -p ContainerImageTag=v2
az acr repository show-tags -n "$ACR" --repository report-api -o table     # v1, v2

# Rolling update with 1 replica: maxSurge 25% rounds up to 1, maxUnavailable rounds down to 0,
# so the new pod starts first and gets traffic only after its readiness probe passes. No downtime.
sed "s/<ACR>/$ACR/" report-api.yaml > report-api.rendered.yaml
kubectl apply -n report -f report-api.rendered.yaml
kubectl rollout status deploy/report-api -n report

# Without this rule NGINX answers its own "404 Not Found ... nginx": the controller works, no route matches.
kubectl apply -n report -f report-api-ingress.yaml
LBIP=$(kubectl get svc nginx -n app-routing-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s "http://$LBIP/info"; echo     # {"region":"swedencentral","pod":"report-api-...","sqlHost":"<sql>.database.windows.net"}
# Path: laptop -> Azure LB -> NGINX pod -> Service report-api -> report-api pod -> SQL over the private endpoint

# =========================================================================
# 3. Global entry point
# =========================================================================
# Front Door lives under the Microsoft.Cdn provider. Its RG is global and kept OUTSIDE Sweden Central:
# RG location = where metadata lives; during an SWC outage we must still be able to change Front Door.
az provider register -n Microsoft.Cdn
az group create -n rg-lab-global -l northeurope --tags owner=arslan env=lab

# Blocked: "Free Trial and Student account is forbidden for Azure Frontdoor resources."
# Options: Traffic Manager (DNS-based, allowed on trial) or upgrade to Pay-As-You-Go.
# Regional Application Gateway alone doesn't survive a region outage: it still needs a global layer above it.
# Next: Traffic Manager, priority routing, probe /healthz, then the outage drill.
