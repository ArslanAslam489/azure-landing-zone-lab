# Level 1 — Governance: management groups, Policy, RBAC

## What happened
- `Require a tag on RG` was not assigned at first, so an untagged RG was created. Lesson: verify assignments with `az policy assignment list --scope $MG`.
- Deny error shows effect, assignment scope, the failed expression (`tags[owner] Exists false`) and exemptions — the troubleshooting evidence.
- `deny-public-ip` at the spoke RG: spoke denied, hub allowed. Scoped low because the hub Firewall needs a public IP.
- Owner created a container with `--auth-mode login`: container operations are **Actions** (Owner has `*`). Blob read/write are **DataActions** (Owner has none) → 403.
- Portal upload worked as Owner because the portal used the **access key** (Owner has `listKeys`), bypassing RBAC. Switching to Entra auth → denied.
- Fixed with `Storage Blob Data Contributor` on the storage account.
- Defender for Cloud auto-assigned "ASC Default" (audit) at the subscription; it flagged the storage account.

## Concepts
- Policy = what may exist (scope-based, applies to everyone). RBAC = who can do what at which scope.
- Location policy restricts where resources live, not where users sign in from (that is Conditional Access).
- Tags are metadata only; they grant no access. Real "who created it" = Activity Log caller.
- Entra issues tokens for both planes; ARM is only on the control plane. Data plane goes straight to the service endpoint.

## Interview answers
## Gaps
- Skipped predictions several times; RG name typo (`ng-` vs `rg-`) — read every command before running.
