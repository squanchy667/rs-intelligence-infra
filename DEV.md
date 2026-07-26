# Dev / test environments — runbook (2026-07-19 env model)

Two **Lightsail** boxes (~$5/mo each, 1 GB), each running the whole app via
docker-compose: **postgres + api + caddy** (no Ollama). Caddy serves the
static UI at `/` and proxies `/api/*` to the API on the **same origin**, so
the UI build (`NEXT_PUBLIC_API_URL=""`) works unchanged.

## The env table

| Env | Box | Branch (dara-v2, dara-v2-ui, rs-intelligence-infra) | Script target | TF root | Role | Who lands here |
|---|---|---|---|---|---|---|
| **dev** | Ofek's internal box (today "dev2") | `dev` | `dev` | `environments/dev2` | anything goes — features/experiments land first, deployed freely from any local tree | every feature/experiment |
| **test** | the review box (today "QA box") | `test` | `test` | `environments/dev` | in-work preview for review — **cherry-picked** features from `dev` + **blessed dumps only** | curated promotions |
| **staging** *(future)* | new box + real domain | `staging` (frozen for now) | — not wired yet — | — TBD — | pre-prod with domain/TLS/real config | promotions from `test` |
| **prod** *(future)* | new box | `main`/`prod` | — not wired yet — | — TBD — | production | promotions from `staging` |

Neither `dev` nor `test` is the ECS/ALB/RDS `environments/staging` architecture
(a *third*, unrelated TF root used by `scripts/{sleep,wake,deep-sleep,deep-wake,deep-deep-sleep,deep-deep-wake}.sh`
for the full AWS integration-gate stack) — don't confuse the two "staging"s:
the **branch** `staging` (frozen, see below) names a *future Lightsail-tier
env slot*; the **TF root** `environments/staging` names the *existing* ECS
stack. They happen to share a word, not a purpose.

## Flow

```
feature branch → dev → (cherry-pick) → test → (future) staging → (future) prod
```

**Rule: an env only ever runs its own branch** — "what's on the box" is
always answerable by `git log <branch>`. This is enforced in code for
`test` (see "Branch-pinned deploys" below), and by discipline for `dev`.

## Branch semantics

- **`dev`** — Ofek's sandbox line. Low-ceremony pushes (agents still never
  push). Feature branches merge into `dev`.
- **`test`** — receives only **cherry-picked** commits promoted from `dev`.
  This is where the review gate lives — it moved from "push to the mainline"
  to "promotion time," which is where it always belonged.
- **`staging`** — **FROZEN**, reserved for the future domain env. Not
  deleted (history references it everywhere) and not currently deployed
  anywhere. When the staging box exists, `staging` resumes as the promotion
  target from `test`.
- Docs repos (`dara-*-docs`) stay on `main` — no env semantics there.

### Mapping from the old (pre-2026-07-19) world

Before this reorg, both code repos used one overloaded branch, `staging`:
LOCAL `staging` tips (backend ahead 23 / ui ahead 10 at cutover) = what the
dev2 box ran → became **`dev`**. ORIGIN `staging` = what the QA box ran →
became **`test`**. `dev = git branch dev staging` (local tip);
`test = git branch test origin/staging` (origin tip at cutover).

## Box roles / script target vocabulary

**⚠️ Vocabulary flip, read carefully:** the OLD script targets were
`feature` (→ today's dev2 box) and `dev` (→ today's QA/review box). Under
the new model, **`dev` now means the INTERNAL box** (old `feature`) and
**`test` means the review box** (old `dev`) — a bare `dev` invocation out of
habit now hits the *opposite* box from what it used to.

- `feature` is accepted as a **deprecated alias** for `dev` (prints a
  warning) — safe, unambiguous, keep using it if you want the warning as a
  reminder to switch.
- `dev` (typed bare) prints a one-line notice — *"target 'dev' = the
  INTERNAL box (environments/dev2) under the 2026-07-19 model; the review
  box is now 'test'"* — and **pauses 3 seconds** before proceeding, so a
  habit-typed `dev` can be Ctrl-C'd. Pass `--yes` to skip the pause.
- `test` needs no guard — it's a new word, no old muscle memory collides
  with it.

| Role | Script target | TF root | State key | Key file | Canonical URL | Fallback URL | AWS name prefix |
|---|---|---|---|---|---|---|---|
| **dev** (internal) — new/experimental work lands here first, from any local tree | `dev` (`feature` = deprecated alias) | `environments/dev2` | `dev2/terraform.tfstate` | `feature_box_key.pem` | `https://dev.<ip-with-dashes>.sslip.io` | `https://<ip-with-dashes>.sslip.io` | `rs-intelligence-dev2-*` |
| **test** (review) — cherry-picked `test`-branch code + blessed dumps only | `test` (old target name was `dev` — CAUTION) | `environments/dev` | `dev/terraform.tfstate` | `dev_box_key.pem` | https://test.54-195-65-131.sslip.io | https://54-195-65-131.sslip.io | `rs-intelligence-dev-*` |

**⚠️ TF directory names are IMMUTABLE — S3 state keys:** the internal box
lives under `environments/dev2` and the review box under `environments/dev`.
Both directory names predate this vocabulary (dev2 was created second; `dev`
predates the split) and **must not be renamed** — renaming would churn the
S3 state key and changing the `environment` Terraform variable would
recreate the box (new IP, new URL). Likewise the `.pem` key filenames
(`feature_box_key.pem` / `dev_box_key.pem`) are kept as-is rather than
renamed to match the new target words — they're local artifacts (gitignored,
re-derived from `terraform output` each run), renaming them buys nothing and
just adds churn. **Think in `dev` / `test` everywhere except inside
`environments/`, where `dev2 = dev` and `dev = test`.**

- IaC: `environments/dev2/` (dev/internal) + `environments/dev/` (test/review),
  both wiring only `modules/dev-box/`.
- App: `dara-v2/docker-compose.dev.yml` + `dara-v2/deploy/Caddyfile`.
- Scripts: `scripts/dev-deploy.sh <dev|test> [--yes]` (code/UI/image) ·
  `scripts/dev-seed.sh <dev|test> [dump.sql.gz] [--yes]` (data) ·
  `scripts/make-seed.sh` (cut a blessed dump artifact, no target — always
  local).

## Branch-pinned deploys (the model's core guarantee)

- **`dev-deploy.sh test`** never builds from the working tree. It runs
  `git archive test | tar -x` into a throwaway temp dir for **both**
  `dara-v2` and `dara-v2-ui` (checkouts sit on `dev` day-to-day — the test
  deploy must not accidentally ship whatever's currently checked out), `npm
  ci` there (a fresh archive has no `node_modules`), builds from that pinned
  tree, and refuses with a clear error if either repo has no local `test`
  branch. This is what makes "what's on the test box = `git log test`"
  actually true.
- **`dev-deploy.sh dev`** stays tree-based — it builds from whatever's
  currently checked out, since `dev` is Ofek's sandbox and deliberately
  supports "deploy this random experiment right now." It prints a
  **non-blocking warning** if either repo's checkout isn't on `dev`, so an
  accidental deploy-from-the-wrong-branch is visible but never blocked.

## Create a box (once per target)

Dev (internal) box (first-time setup):
```sh
cd environments/dev2
terraform init
terraform apply -var-file=terraform.tfvars      # ~2-3 min; creates Lightsail box + static IP
terraform output url                            # http://<static-ip>
```

The test (review) box already exists — no `terraform apply` needed unless
recreating it from scratch (same commands, but `cd environments/dev`).

## Deploy the current build

```sh
cd ..                                # repo root (rs-intelligence-infra)
./scripts/dev-deploy.sh dev          # deploy to the internal box (tree-based)
./scripts/dev-deploy.sh test         # deploy to the review box (branch-pinned to `test`)
./scripts/dev-deploy.sh dev --yes    # skip the 3s habit-typed-dev pause
```
Builds the UI + amd64 API image, ships them, `docker compose up -d`. Redeploy
after code changes = re-run `dev-deploy.sh <target>` (add `dev-seed.sh` only
when you want to refresh the data). The API entrypoint runs
`alembic upgrade head` on boot; a seed dump whose `alembic_version` matches
the deployed code stays a no-op.

## Seed data

```sh
./scripts/dev-seed.sh dev                     # dev: pg_dump the local DB → restore
./scripts/dev-seed.sh test path/to/dump.sql.gz   # test: restore from a blessed dump
```
With no second argument, `dev-seed.sh` pg_dumps whatever is currently in your
local `dara_v2` DB. With a second argument (a `.sql.gz` path), it skips the
local dump and ships that file instead. Same `dev`/`test` guard + `--yes` as
`dev-deploy.sh` (a bare `dev-seed.sh dev` pauses 3s with a notice).

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

## PROMOTION POLICY (discipline, not enforced in code — except the branch pin)

- **`test` box** only ever gets: features cherry-picked from `dev` into the
  `test` branch (both `dara-v2` and `dara-v2-ui` repos), deployed via
  `dev-deploy.sh test` (branch-pinned — see above, code-enforced), and
  reseeded **only** from a blessed dump under `snapshots/seeds/` via
  `dev-seed.sh test <dump.sql.gz>` — never a live local `pg_dump`
  (`dev-seed.sh test` with no second arg), because local may contain
  mid-campaign experiments.
- **`dev` box** takes any local tree, any time — `dev-deploy.sh dev` +
  `dev-seed.sh dev` with no dump argument is the normal flow.

## URL / DNS

Both boxes are reachable via **sslip.io** (any subdomain prefix still
resolves to the embedded IP, so `dev.<ip>.sslip.io` and `<ip>.sslip.io` both
route to the same box; Caddy auto-provisions a Let's Encrypt cert per
hostname and redirects 80→443). When `domain.env` sets `BASE_DOMAIN`, the
canonical host becomes `<target>.$BASE_DOMAIN` and the sslip names stay as
fallback aliases (dual-host — LE cert per name).

- **dev (internal)**: still sslip-only today —
  `https://dev.<ip-with-dashes>.sslip.io` + bare-IP fallback (derive after
  first `terraform apply` in `environments/dev2`). Optional later:
  `dev.$BASE_DOMAIN` A → dev box IP.
- **test (review)**: canonical **https://test.rs-intel.com** (GoDaddy A →
  `54.195.65.131`, live 2026-07-26). Fallbacks still live:
  **https://test.54-195-65-131.sslip.io** and
  **https://54-195-65-131.sslip.io**.

`dev-deploy.sh` reads optional `domain.env` (`BASE_DOMAIN=…`) in the infra
root, then builds `SITE_ADDRESS` as space-separated hosts and passes it to
`docker compose up`. Caddy's `{$SITE_ADDRESS::80}` accepts multiple site
addresses on one block (`deploy/Caddyfile` in `dara-v2`). Keep
`key_type rsa2048` (legacy-client cipher path).

**Cutover checklist (test):** (1) A record `test.<domain>` → box static IP,
TTL low; (2) `domain.env` with `BASE_DOMAIN`; (3) deploy or
`SITE_ADDRESS='…' docker compose up -d --force-recreate caddy`; (4) verify
LE cert RSA + `/api/health` + dual-host sslip still OK.

## One-time step on a NEW box: set JWT_SECRET

`docker-compose.dev.yml` reads `JWT_SECRET` from `/opt/dara/.env` on the box.
Set it once, right after the first deploy, so it survives future redeploys
(redeploys only ever touch the `ENV_LABEL` line in `.env` — see below):

```sh
ssh -i feature_box_key.pem ubuntu@<ip> 'umask 077; echo "JWT_SECRET=$(openssl rand -hex 32)" > /opt/dara/.env'
```

**⚠️ Never run this against the test box's existing `/opt/dara/.env`** — it
already has a live (rotated) secret; overwriting it invalidates every
existing session token on that box.

## ENV chip — how a box tells you what it is

Every `dev-deploy.sh <target>` run injects `ENV_LABEL=<target>` into
`/opt/dara/.env` on the box — idempotent (replaces an existing `ENV_LABEL=`
line if present, leaves everything else, notably `JWT_SECRET`, untouched).
`docker-compose.dev.yml` passes it into the `api` container's environment;
`dara_v2/config.py`'s `Settings.env_label` (pydantic-settings, default
`"local"`) picks it up, and `/api/health` returns it as `"env"`. The UI top
bar reads it off the existing `/api/health` poll (`useHealth()` — no new
request added) and renders a small badge: **DEV** (amber) when `env=dev`,
**TEST** (blue) when `env=test`, nothing when `env=local` or absent (plain
local dev, or any future env not yet wired to `ENV_LABEL`). Lands on `dev`
first; promotes to `test` with the next cherry-pick like any other feature.

## Smoke

```sh
SITE=test.54-195-65-131.sslip.io   # or the dev box's derived host (dev.<ip>.sslip.io)
curl https://$SITE/api/health
# open https://$SITE  → login smoke@dara.local / DaraDemo2026!  → /gush, /deals
# the top-bar chip should read TEST (blue) or DEV (amber) accordingly
```
The smoke user (`smoke@dara.local`) isn't provisioned by the scripts — it
travels inside whichever `pg_dump` you seed from (local or blessed).

## Stop paying (~$5/mo per box while up)

```sh
cd environments/dev2 && terraform destroy -var-file=terraform.tfvars   # dev (internal) box
cd environments/dev  && terraform destroy -var-file=terraform.tfvars   # test (review) box
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
- **`test` deploys are slower** than `dev` deploys — the branch-pinned build
  archives a fresh tree and runs `npm ci` from scratch (no cached
  `node_modules`), on top of the same UI-build + docker-buildx steps `dev`
  does.
- **Verify-line amenities note**: `dev-seed.sh`'s post-restore row-count
  check queries `presentation_deals` and `amenities` — a low or zero
  `amenities` count after a restore usually means the dump predates the
  amenities backfill, not a broken restore.
- **Ollama dropped on both boxes** → the LLM report-narrative endpoints don't
  work here; the deals / gush map / developer / amenities features (what's
  under test) do.
- **SSH keys**: `terraform output -raw private_key_pem` is written to
  `<key-file>` (`feature_box_key.pem` for `dev`/`environments/dev2`,
  `dev_box_key.pem` for `test`/`environments/dev`) by the scripts (gitignored
  — do not commit). Kept as historical filenames — see the TF-directory note
  above for why they don't follow the new `dev`/`test` words.
- Cost surface check: `aws lightsail get-instances` → two `micro_3_0`
  instances (`rs-intelligence-dev-*` and `rs-intelligence-dev2-*`); no
  RDS/ALB/NAT/CloudFront created by either env.
