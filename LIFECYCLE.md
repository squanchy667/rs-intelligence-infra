# Staging Stack — Lifecycle (sleep / wake tiers)

The `rs-intelligence-staging` stack (eu-west-1, AWS account 502140064073) is **not meant to run continuously**. It has four cost tiers, driven by the scripts in `scripts/`. This file is the runbook the bare scripts don't otherwise document.

## Current state

❄️ **DEEP-DEEP-FROZEN since 2026-06-03** (~$3–4/mo).
- RDS snapshot: `rs-intelligence-staging-final-20260603` (see `state/snapshots/latest.json`).
- It was a **manual** deep-deep freeze: the RDS snapshot was taken, the optional pg_dump was **not** — wake works via the snapshot path.
- The frontend (S3 + CloudFront) still serves; `/api/*` returns errors (backend is torn down).
- Local-first is authoritative for dev/demo; the frozen stack is not needed for that.

## Tiers

| tier | script | what it does | idle cost | wake | wake time |
|---|---|---|---|---|---|
| **awake** | `wake.sh` | ECS service at 1 task; full stack | ~$65/mo (up to ~$165 with VPC interface endpoints) | — | — |
| **sleep** | `sleep.sh` | ECS → 0 tasks; ALB + NAT + RDS stay up | ~$50/mo | `wake.sh` | ~90 s |
| **deep-sleep** | `deep-sleep.sh` | destroy ECS + NAT + private route table; keep RDS/ALB/CloudFront/S3/Secrets/ECR/VPC | ~$23/mo | `deep-wake.sh` (terraform apply) | ~3–5 min |
| **deep-deep-sleep** ← *current* | `deep-deep-sleep.sh` | pg_dump→S3+local + RDS snapshot, then destroy RDS + ALB + NAT + ECS; keep snapshot/CloudFront/S3/Secrets/ECR/VPC shell | **~$3–4/mo** | `deep-deep-wake.sh` (restore RDS from snapshot, recreate stack) | ~10–15 min |

Cost breakdown at deep-deep idle: RDS snapshot storage ~$2/mo (20 GB) · S3 ~$0.50/mo · Secrets Manager ~$1/mo · CloudFront $0 idle.

## Wake runbook (from current deep-deep-frozen state)

```sh
cd rs-intelligence-infra
./scripts/deep-deep-wake.sh      # reads state/snapshots/latest.json → terraform apply -var=restore_from_snapshot_id=<id>
# recreates RDS-from-snapshot + ALB + NAT + private RT + ECS; CloudFront origin auto-updates; ~10-15 min
# then health-checks via CloudFront
```

Same CloudFront URL, same admin user, same data (as of the snapshot date). To go back to frozen afterward: `./scripts/deep-deep-sleep.sh` (set `CONFIRM=YES`).

## DR / offline copy

`deep-deep-sleep.sh` normally also writes an offline `pg_dump` to `state/snapshots/dumps/<id>.sql.gz` (survives an AWS account closure). The current freeze skipped it (manual). If you need an account-closure-proof copy, run a one-off dump before any account changes.

## Related
- Cost threshold: <$10/mo is fine (deep-deep at ~$3–4 is well under).
- Snapshot state: `state/snapshots/latest.json` + `rs-intelligence-staging-final-20260603.json`.
- Workspace status: `../STATE.md`.
