# Level 6 — AKS: workload identity, scaling, failures

> **Status: planned, not yet run.** (SEC-2092 from Level 3 lands here: remove the SQL password from Kubernetes.)

## Ticket (planned)
> **SEC-2092** — "Remove the SQL password from Kubernetes entirely." + **OPS-77** — "The portal is slow every morning at 8:00."

## What the level will cover
- Workload identity (federated credential) vs pod identity vs Kubernetes Secrets.
- HPA vs KEDA vs cluster autoscaler: who scales what, on which signal; pre-scaling before a known spike.
- Requests/limits and why the scheduler needs them (seen in Level 7: NGINX Pending at 88% requested).
- Failure drills: ImagePullBackOff, CrashLoopBackOff, OOMKilled, Running but 0/1 Ready.

## Prediction
## What happened
## Break-fix (break → symptom → diagnose → fix)
## Interview answers
## What I learned / gaps
