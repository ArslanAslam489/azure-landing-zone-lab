# Level 0 — Basics

## What happened
- `az login` returned no subscriptions: MFA is enforced per tenant (AADSTS50076). Fixed with `az login --tenant <tenant-id>`.
- Passed the subscription ID to `--tenant` → AADSTS90002 "tenant not found". Tenant ID ≠ subscription ID.
- Quota list was empty: `Microsoft.Compute` not registered on a fresh subscription. Trial quota: 4 regional vCPUs.
- Old `subscription` CLI extension broke `az account management-group` (`No module named 'msrestazure'`). Removed it.

## Concepts
- Hierarchy: Tenant → Management group → Subscription → Resource group → Resource.
- Tenant Root Group ID = tenant ID. New subscriptions land under it by default.
- ARM = the single control-plane API (portal, CLI, Terraform all call it): authenticate (Entra) → authorize (RBAC) → Policy → route to the resource provider.
- Resource provider = the service behind a namespace (`Microsoft.Compute`); a subscription must register it before use. Not the same as quota.

## Interview answers
## Gaps
- Mixed up resource provider with quota.
