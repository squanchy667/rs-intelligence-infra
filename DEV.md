# Feature / shared-dev environments — runbook

Two **Lightsail** boxes (~$5/mo each, 1 GB), each running the whole app via
docker-compose: **postgres + api + caddy** (no Ollama). Caddy serves the
static UI at `/` and proxies `/api/*` to the API on the **same origin**, so
the UI build (`NEXT_PUBLIC_API_URL=""`) works unchanged.

These are the cheap, always-on tiers of the feature → dev (QA) → staging →
prod pipeline. Neither is the ECS/ALB/RDS staging architecture — **staging
stays the real integration gate**.

## Box roles

| Role | Script target | TF root | State key | Key file | URL | AWS name prefix |
|---|---|---|---|---|---|---|
| **Feature box** — new/experimental work (Bat Yam, tenders, …) lands here first, from any local tree | `feature` | `environments/dev2` | `dev2/terraform.tfstate` | `feature_box_key.pem` | run `terraform -chdir=environments/dev2 output -raw static_ip`, host = `<ip-with-dashes>.sslip.io` | `rs-intelligence-dev2-*` |
| **Shared dev box** — QA tests here; only cherry-picked, pushed staging code + blessed dumps | `dev` | `environments/dev` | `dev/terraform.tfstate` | `dev_box_key.pem` | https://54-195-65-131.sslip.io | `rs-intelligence-dev-*` |

**⚠️ Directory naming:** the feature box lives under `environments/dev2` — the
`dev2` name is historical (it was created second; the `environments/dev`
directory and its S3 state key predate the split and must not be renamed —
renaming would churn the state key, and changing its `environment` variable
would recreate the box and change the QA URL). The script targets
(`feature` / `dev`) are the names to think in; only inside `environments/`
does `dev2 = feature` apply.

- IaC: `environments/dev2/` (feature) + `environments/dev/` (shared dev),
  both wiring only `modules/dev-box/`.
- App: `dara-v2/docker-compose.dev.yml` + `dara-v2/deploy/Caddyfile`.
- Scripts: `scripts/dev-deploy.sh <feature|dev>` (code/UI/image) ·
  `scripts/dev-seed.sh <feature|dev> [dump.sql.gz]` (data) ·
  `scripts/make-seed.sh` (cut a blessed dump artifact).

## Create a box (once per target)

Feature box (first-time setup):
```sh
cd environments/dev2
terraform init
terraform apply -var-file=terraform.tfvars      # ~2-3 min; creates Lightsail box + static IP
terraform output url                            # http://<static-ip>
```

The shared dev box already exists — no `terraform apply` needed unless
recreating it from scratch (same commands, but `cd environments/dev`).

## Deploy the current build

```sh
cd ..                                # repo root (rs-intelligence-infra)
./scripts/dev-deploy.sh feature      # deploy to the feature box
./scripts/dev-deploy.sh dev          # deploy to the shared dev (QA) box
```
Builds the UI + amd64 API image, ships them, `docker compose up -d`. Redeploy
after code changes = re-run `dev-deploy.sh <target>` (add `dev-seed.sh` only
when you want to refresh the data). The API entrypoint runs
`alembic upgrade head` on boot; a seed dump whose `alembic_version` matches
the deployed code stays a no-op.

## Seed data

```sh
./scripts/dev-seed.sh feature                    # feature: pg_dump the local DB → restore
./scripts/dev-seed.sh dev path/to/dump.sql.gz    # shared dev: restore from a blessed dump
```
With no second argument, `dev-seed.sh` pg_dumps whatever is currently in your
local `dara_v2` DB. With a second argument (a `.sql.gz` path), it skips the
local dump and ships that file instead.

### Cutting a blessed dump

```sh
./scripts/make-seed.sh
# → snapshots/seeds/dara_v2_<date>_<alembic_head>.sql.gz
```
pg_dumps the local DB, names the artifact by date + alembic head, and appends
a provenance line (date, alembic head, per-city deal counts,
`presentation_deals` count, filename) to `snapshots/seeds/MANIFEST.txt`.
`snapshots/` is gitignored — these are local artifacts, not committed to the
repo.

## PROMOTION POLICY (discipline, not enforced in code)

There is deliberately no guard logic anywhere in these scripts — this is a
runbook rule, not a code-enforced one:

- **Shared dev box (QA)** only ever gets: features cherry-picked/merged into
  `staging` and pushed to `origin/staging` (both `dara-v2` and `dara-v2-ui`
  repos), deployed via `dev-deploy.sh dev` from a checkout matching
  `origin/staging`, and reseeded **only** from a blessed dump under
  `snapshots/seeds/` via `dev-seed.sh dev <dump.sql.gz>` — never a live local
  `pg_dump` (`dev-seed.sh dev` with no second arg), because local may contain
  mid-campaign experiments.
- **Feature box** takes any local tree, any time — `dev-deploy.sh feature` +
  `dev-seed.sh feature` with no dump argument is the normal flow.

## URL / DNS

Both boxes are reachable via **sslip.io** (resolves the embedded IP → the
box's static IP; Caddy auto-provisions a Let's Encrypt cert and redirects
80→443):
- Shared dev (QA): **https://54-195-65-131.sslip.io**
- Feature: derive after first `terraform apply` in `environments/dev2` — the
  hostname is `<ip-with-dashes>.sslip.io`, e.g. `1-2-3-4.sslip.io` for IP
  `1.2.3.4`.

The hostname is derived from each box's static IP by `dev-deploy.sh`
(`SITE_ADDRESS`), so a recreate with a new IP just works. To use a branded
domain instead: point an A record at the static IP and set
`SITE_ADDRESS=yourdomain.com`.

## One-time step on a NEW box: set JWT_SECRET

`docker-compose.dev.yml` reads `JWT_SECRET` from `/opt/dara/.env` on the box.
Set it once, right after the first deploy, so it survives future redeploys
(redeploys never touch `.env`):

```sh
ssh -i feature_box_key.pem ubuntu@<ip> 'umask 077; echo "JWT_SECRET=$(openssl rand -hex 32)" > /opt/dara/.env'
```

**⚠️ Never run this against the shared dev box's existing `/opt/dara/.env`** —
it already has a live (rotated) secret; overwriting it invalidates every
existing session token on that box.

## Smoke

```sh
SITE=54-195-65-131.sslip.io   # or the feature box's derived host
curl https://$SITE/api/health
# open https://$SITE  → login smoke@dara.local / DaraDemo2026!  → /gush, /deals
```
The smoke user (`smoke@dara.local`) isn't provisioned by the scripts — it
travels inside whichever `pg_dump` you seed from (local or blessed).

## Stop paying (~$5/mo per box while up)

```sh
cd environments/dev2 && terraform destroy -var-file=terraform.tfvars   # feature box
cd environments/dev  && terraform destroy -var-file=terraform.tfvars   # shared dev (QA) box
```
This removes the box + static IP. (There's no RDS/ALB/NAT to leak cost — the
only standing resource per box is the instance.) Re-create with
`terraform apply` + `dev-deploy.sh` + `dev-seed.sh`.

## Notes / caveats

- **cloud-init is POSIX `sh`**, not bash — `modules/dev-box/` user_data must
  stay POSIX-compliant (no bashisms). Do not "fix" this by adding a bash
  shebang; it's deliberate.
- **`SKIP_MIGRATIONS=1` / seed-from-dump rationale**: a blessed dump already
  carries the alembic head matching the code it was cut from, so restoring it
  makes the API's `alembic upgrade head` a no-op when heads line up. If you
  ever seed a dump whose head is *behind* the deployed code, the API will run
  real migrations against seeded data on boot — that's expected, not a bug.
- **Docker Desktop must be running locally** — `dev-deploy.sh` builds the API
  image via `docker buildx build --platform linux/amd64 ... --load`, which
  needs a running local Docker daemon (even though the target box is a
  different arch/host).
- **Verify-line amenities note**: `dev-seed.sh`'s post-restore row-count
  check queries `presentation_deals` and `amenities` — a low or zero
  `amenities` count after a restore usually means the dump predates the
  amenities backfill, not a broken restore.
- **Ollama dropped on both boxes** → the LLM report-narrative endpoints don't
  work here; the deals / gush map / developer / amenities features (what's
  under test) do.
- **SSH keys**: `terraform output -raw private_key_pem` is written to
  `<target>_box_key.pem` (`feature_box_key.pem` / `dev_box_key.pem`) by the
  scripts (gitignored — do not commit).
- Cost surface check: `aws lightsail get-instances` → two `micro_3_0`
  instances (`rs-intelligence-dev-*` and `rs-intelligence-dev2-*`); no
  RDS/ALB/NAT/CloudFront created by either env.
