# Dev / test environments — runbook (2026-07-19 env model)

Two **Lightsail** boxes (~$5/mo each, 1 GB), each running the whole app via
docker-compose: **postgres + api + caddy** (no Ollama). Caddy serves the
static UI at `/` and proxies `/api/*` to the API on the **same origin**, so
the UI build (`NEXT_PUBLIC_API_URL=""`) works unchanged.

Deploys now flow through one of two paths: this manual runbook
(`scripts/dev-deploy.sh`, always available), or the GitHub Actions CI/CD
ladder built 2026-07-30 and **inert until Ofek activates it** — see "The
CI/CD ladder" right after the env table below.

## The env table

| Env | Box | Branch (dara-v2, dara-v2-ui, rs-intelligence-infra) | Script target | TF root | Role | Who lands here |
|---|---|---|---|---|---|---|
| **dev** | Ofek's internal box (today "dev2") | `dev` | `dev` | `environments/dev2` | anything goes — features/experiments land first, deployed freely from any local tree | every feature/experiment |
| **test** | the review box (today "QA box") | `test` | `test` | `environments/dev` | in-work preview for review — **ff-merged** features from `dev` + **blessed dumps only** | curated promotions |
| **staging** *(future)* | new box + real domain | `staging` (frozen for now) | — not wired yet — | — TBD — | pre-prod with domain/TLS/real config | promotions from `test` |
| **prod** *(future)* | new box | `main`/`prod` | — not wired yet — | — TBD — | production | promotions from `staging` |

Neither `dev` nor `test` is the ECS/ALB/RDS `environments/staging` architecture
(a *third*, unrelated TF root used by `scripts/{sleep,wake,deep-sleep,deep-wake,deep-deep-sleep,deep-deep-wake}.sh`
for the full AWS integration-gate stack) — don't confuse the two "staging"s:
the **branch** `staging` (frozen, see below) names a *future Lightsail-tier
env slot*; the **TF root** `environments/staging` names the *existing* ECS
stack. They happen to share a word, not a purpose. **Naming note
(2026-07-30):** the CI ladder's dormant third rung (below) uses branch name
`stg` — that is a *different* branch from the frozen `staging` above, and
now has its own scaffold TF root too: `environments/stg/` (an inert mirror
of `environments/dev`'s Lightsail-box shape, state key
`stg/terraform.tfstate`, **not applied** — see that directory's README).
`environments/cicd` already instantiates `module.stg`'s deploy role/SSM
activation against `environments/stg`'s future box, so once
`environments/stg` is applied the CI/CD side is already wired and waiting.
`staging`/`environments/staging` and `stg`/`environments/stg` are NOT (yet)
the same thing — `staging` stays exactly as documented here. Whether a real
staging tier eventually reuses `stg` or resurrects `staging` is an open
call, not one this doc makes for you.

## The CI/CD ladder (2026-07-30)

A GitHub Actions deploy ladder now sits on top of everything below — built
2026-07-30 (WOs CI-1..CI-4), **inert until Ofek flips it on**. Workflows
live in `dara-v2/.github/workflows/`; the AWS-side plumbing (OIDC roles, S3
artifact bucket, SSM deploy document, CloudTrail alarm) lives in this
repo's `environments/cicd/` (Terraform, reviewed — `terraform plan` = 36
add / 0 change / 0 destroy — but **not yet applied**).

```
push dev  ──▶ checks (light, no DB) ──▶ build + SSM deploy ──▶ health-gate ──▶ autotag dev-ok-<sha>  ──▶ ledger row
push test ──▶ tag-gate (needs dev-ok-* or patch-* AT HEAD) ──▶ checks (full, DB-backed) ──▶ build + SSM deploy ──▶ health-gate ──▶ autotag test-ok-<sha> ──▶ ledger row
push stg  ──▶ same shape as test (needs test-ok-*/patch-*) — DORMANT, see STG_ENABLED below
```

Two switches (both GitHub repo **variables**, not secrets — no GitHub
Environments used here, see the Deviations register at the bottom of this
file):

- **`CICD_ENABLED`** — master switch. Every rung's top-level job carries
  `if: vars.CICD_ENABLED == 'true'`; `false`/unset means every deploy
  workflow no-ops on every push. Currently unset.
- **`STG_ENABLED`** — stg stays dormant even after `CICD_ENABLED` flips
  true, until Ofek separately sets this one. There's no stg box today
  anyway.

**Promotion is fast-forward-only now — cherry-picks are retired.** `dev` →
`test` → `stg` moves by `git merge --ff-only`, not cherry-pick-squash. See
the updated PROMOTION POLICY below — the old cherry-pick instructions are
gone from this file, not just superseded in spirit.

**`patch-*` = Ofek-only bypass.** An annotated tag `patch-<name>` at HEAD
lets a push through `tag-gate.sh` without the upstream `<env>-ok-*` tag
(hotfix path). Tagger identity is checked and logged but only
`::warning`-advisory — a local git tagger field is trivially spoofable, so
this is an audit trail, not access control.

**Rollback = redeploy-by-tag**, not a new push. `Actions → Redeploy`
re-ships an already-tagged sha with no rebuild — reuses the cached S3
artifact (~2 min) if it's still inside the artifact bucket's 60-day expiry,
otherwise the artifact has aged out and the rung rebuilds from the tag's
source instead. Full procedure in the new "Rollback" section below.

### Deploy paths

- **CI is the default path** for dev/test/stg once `CICD_ENABLED=true` — a
  push to `dev`/`test`/`stg` (or a `workflow_dispatch`) is how a normal
  deploy happens going forward.
- **`scripts/dev-deploy.sh` is retained, unchanged in semantics**, now
  serving two purposes: (a) the sandbox/tree-deploy tool for `dev`
  (deliberately not CI-gated — "deploy this random experiment right now"),
  and (b) the **CI-outage fallback** for any env when the ladder itself is
  down or still inert. The one thing CI-3 changed under it: it now emits a
  **single canonical-only `SITE_ADDRESS`** host instead of the old
  space-separated sslip+canonical list — see "URL / DNS" below.

## Flow

```
feature branch → dev → (ff-only merge, CI tag-gated) → test → (future) stg → (future) prod
```

**Rule: an env only ever runs its own branch** — "what's on the box" is
always answerable by `git log <branch>`. This is enforced in code for
`test` (branch-pinned builds, see "Branch-pinned deploys" below — and now
also the CI ladder's own branch-triggered workflows), and by discipline for
`dev`. Cherry-pick promotion (the original 2026-07-19 model) is **retired
as of 2026-07-30** — see PROMOTION POLICY below for the current ff-only
rule and why.

## Branch semantics

- **`dev`** — Ofek's sandbox line. Low-ceremony pushes (agents still never
  push). Feature branches merge into `dev`.
- **`test`** — receives **fast-forward merges** promoted from `dev`
  (cherry-pick retired 2026-07-30 — see PROMOTION POLICY). The review gate
  still lives at promotion time, not push-to-mainline time; it's now also
  machine-enforced by the CI ladder's tag-gate (HEAD must carry a
  `dev-ok-*` tag, or an Ofek `patch-*` override, before `test` deploys).
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
| **dev** (internal) — new/experimental work lands here first, from any local tree | `dev` (`feature` = deprecated alias) | `environments/dev2` | `dev2/terraform.tfstate` | `feature_box_key.pem` | `https://dev.<ip-with-dashes>.sslip.io` today; `https://dev.rs-intel.com` once the CI-3 cutover runs (DNS already live, box not yet cut over — see "URL / DNS") | `https://<ip-with-dashes>.sslip.io` | `rs-intelligence-dev2-*` |
| **test** (review) — ff-merged `test`-branch code + blessed dumps only | `test` (old target name was `dev` — CAUTION) | `environments/dev` | `dev/terraform.tfstate` | `dev_box_key.pem` | **https://test.rs-intel.com** (live since 2026-07-26) | https://test.54-195-65-131.sslip.io + https://54-195-65-131.sslip.io — **both die at the CI-3 cutover** | `rs-intelligence-dev-*` |

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

**The CI ladder gets this same guarantee for free, differently.**
`deploy-dev.yml`/`deploy-test.yml`/`deploy-stg.yml` each trigger only off a
push to their own branch (or a `workflow_dispatch` naming that branch,
enforced by `redeploy.yml`'s branch-match guard) and build from that push's
sha — there's no working-tree ambiguity to guard against, because CI never
has a "current checkout" to accidentally build from.

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

## SSM hybrid activation (boxes as managed nodes)

**Why:** Lightsail instances have no IAM instance-profile attachment
mechanism, so the CI ladder can't reach them the normal EC2-managed-node
way. AWS's hybrid/on-prem activation flow is the documented workaround —
each box registers its SSM agent against a per-env activation (code + id)
minted by `environments/cicd`'s Terraform, and shows up in Systems Manager
as an `mi-*` managed node carrying that activation's IAM role. This is what
lets `ssm:SendCommand` (the deploy document behind the ladder above) reach
a box with no ssh/open-port step anywhere in the CI path.

**Authoritative runbook: `environments/cicd/README.md`** — first-apply
steps, reading the activation id/code (`terraform output -json`, a
sensitive output), the box-side `-register` command, verifying registration
(`aws ssm describe-instance-information` / `list-tags-for-resource`), and
re-creating an expired activation (`terraform apply -replace=...`). This
section only summarizes; edit the runbook there, not here, if the procedure
changes.

- **⚠️ Activations expire ~24h after apply.** Apply + register the box the
  same day, or pass `-var ssm_activation_expiration=<RFC3339>` at apply
  time (AWS max 30 days) if same-day registration isn't realistic.
- **Verify `DeployEnv` tag propagation** to the `mi-*` node right after
  registering (`aws ssm list-tags-for-resource --resource-type
  ManagedInstance --resource-id mi-xxxx`) — the deploy role's
  `SsmSendInstance` IAM condition matches on that tag by default. If the
  tag didn't propagate, set the `managed_instance_id_<env>` tfvar to the
  node's exact ARN and re-apply — `modules/gha-deploy-env` builds in this
  exact fallback path (a hard-pinned instance ID, no tag condition at all)
  precisely because tag-propagation-on-hybrid-activation isn't guaranteed
  to hold for every AWS account/region.

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

**Since CI-3 (2026-07-30)** this always ships a single canonical-only
`SITE_ADDRESS` — see "URL / DNS" below. This script is one of two deploy
paths now (see "Deploy paths" above); CI runs the equivalent
build+ship+up sequence over SSM instead of ssh+rsync.

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

## PROMOTION POLICY (discipline, mostly enforced in code now)

**Code promotion is fast-forward-only, 2026-07-30 — cherry-picks are
retired.** `dev` → `test` → `stg` moves by `git merge --ff-only` (both
`dara-v2` and `dara-v2-ui` repos), never a cherry-pick-squash. This
replaces the original 2026-07-19 "cherry-pick features from dev into test"
rule outright — ff-only is what lets the CI ladder's tag-gate reason about
"is `test`'s HEAD something `dev` has already blessed" without diffing
trees. The still-manual step is the merge itself (Ofek decides *when* to
promote); once the promoted branch's tip carries the upstream `<env>-ok-*`
CI tag (or an Ofek `patch-*` override), pushing it deploys automatically.

- **`test` box** only ever gets: code that is `test = git merge --ff-only
  dev` (both repos) with HEAD carrying a `dev-ok-*` CI tag or a `patch-*`
  override, deployed either by the CI ladder (`push test`, once
  `CICD_ENABLED=true`) or manually via `dev-deploy.sh test` (branch-pinned
  — see above, code-enforced either way), and reseeded **only** from a
  blessed dump under `snapshots/seeds/` via `dev-seed.sh test
  <dump.sql.gz>` — never a live local `pg_dump` (`dev-seed.sh test` with no
  second arg), because local may contain mid-campaign experiments. This
  data rule is unchanged by the CI ladder — CI never touches seed data,
  only code + image.
- **`dev` box** takes any local tree, any time — `dev-deploy.sh dev` +
  `dev-seed.sh dev` with no dump argument is the normal flow. Once
  `CICD_ENABLED=true`, a `push` to the `dev` branch ALSO triggers the CI
  ladder's light-rung deploy to the same box — the manual script and a
  routine `git push` aren't mutually exclusive, just two doors onto
  `environments/dev2`.
- **Two ledgers, two owners.** Every CI-driven deploy appends a row to
  `dara-v2`'s orphan `ci-ledger` branch (`LEDGER.md`) automatically — that's
  the **machine** record of "what got deployed, when, by what run." This
  repo's `PROMOTIONS.md` stays the **human** record of promotion
  decisions/dumps/reasoning. The two are never merged — see PROMOTIONS.md's
  own header note.

## URL / DNS

**Canonical-only hosts, as of the CI-3 Caddyfile (2026-07-30) — but the
boxes themselves are NOT cut over yet.** `deploy/Caddyfile` in `dara-v2`
and this repo's `dev-deploy.sh` both now build/serve **exactly one
hostname per box** (`dev.rs-intel.com` / `test.rs-intel.com`) — the old
dual-host sslip+canonical Caddy config is retired in the code, but each box
keeps running whatever Caddyfile it was last deployed with until someone
runs the cutover. **Full operator runbook:
`dara-v2/deploy/CUTOVER_RUNBOOK_CI-3.md` — every step is Ofek's hand,
nothing there runs unattended.**

- **dev (internal)**: A-record verified 2026-07-30 (`dig +short
  dev.rs-intel.com` → `54.155.62.174`) — the DNS precondition is satisfied,
  but the box-side cutover (redeploying with the CI-3 Caddyfile +
  `domain.env`) hasn't run yet. Until then, treat `dev` as still on its
  pre-cutover config — sslip-only, per the table above.
- **test (review)**: canonical **https://test.rs-intel.com** already live
  (GoDaddy A → `54.195.65.131`, DNS/TLS cut over 2026-07-26 — that predates
  CI-3's Caddyfile rewrite). Because the *dual-host* Caddy config is what's
  still deployed there today, `test` currently ALSO answers on
  `https://test.54-195-65-131.sslip.io` and bare
  `https://54-195-65-131.sslip.io` — **both die** once the CI-3 Caddyfile
  is deployed to that box too.

**DNS-before-deploy is now a hard ordering gate, not just good practice.**
Once the CI-3 Caddyfile is live on a box, Caddy requests a Let's Encrypt
cert for exactly `{$SITE_ADDRESS}` — one host, no fallback list. If the
A-record isn't resolving yet, issuance fails and the canonical vhost serves
nothing; there's no sslip safety net left to fall back on. Every future
cutover (stg, or re-cutting an existing box) must confirm the A-record
first — see the runbook's §2 "Ordering gate."

`dev-deploy.sh` still reads optional `domain.env` (`BASE_DOMAIN=…`) in the
infra root; post-CI-3 it builds `SITE_ADDRESS` as a **single** canonical
host (`<target>.$BASE_DOMAIN`), not a space-separated list. If
`domain.env`/`BASE_DOMAIN` is absent, it falls back to a single sslip host
(bootstrap-only — the script prints a loud warning) rather than the old
sslip+canonical dual-host shape. Keep `key_type rsa2048` (legacy-client
cipher path — see the Kaspersky/AV lesson next).

**NRD/AV caveat carries forward unchanged:** `rs-intel.com` was a newly
registered domain (bought 2026-07-26); some endpoint AV/DNS-filtering
products distrust NRDs for their first days-to-weeks, and `key_type
rsa2048` in the Caddyfile is what fixed the original Kaspersky
`ERR_SSL_VERSION_OR_CIPHER_MISMATCH` incident on this same domain (see
`project_darareports_env_model.md` for the full forensic chain, and the
runbook's §7 for the "verify server-externally-first" playbook if a tester
reports the canonical host unreachable post-cutover).

**Cutover checklist (test, 2026-07-26 — DNS/TLS bring-up only, predates
CI-3):** (1) A record `test.<domain>` → box static IP, TTL low; (2)
`domain.env` with `BASE_DOMAIN`; (3) deploy or `SITE_ADDRESS='…' docker
compose up -d --force-recreate caddy`; (4) verify LE cert RSA +
`/api/health` + dual-host sslip still OK. **This checklist describes the
original dual-host DNS/TLS bring-up only — for the canonical-host-only
cutover itself, use `CUTOVER_RUNBOOK_CI-3.md`.**

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

The CI ladder's SSM deploy document follows this exact same idempotent
convention on the box's `/opt/dara/.env` — its strip-list only touches
`ENV_LABEL`/`GIT_SHA`/`UI_GIT_SHA`/`SV_TAG` lines, leaving `JWT_SECRET` (and
anything else already in the file) untouched.

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
first; promotes to `test` with the next ff-only merge like any other
feature (cherry-pick retired — see PROMOTION POLICY).

CI-deployed boxes additionally stamp `UI_GIT_SHA` and `SV_TAG` into the same
`/opt/dara/.env` (soft fields in `/api/health` until the parallel SV-12 lane
lands) — same idempotent strip-and-replace convention as `ENV_LABEL`/
`GIT_SHA` above.

## Smoke

**Post-deploy contract check: `scripts/validate-box.sh <dev|test|stg>`**
(lives in `dara-v2`, WO CI-4) — the same check the CI ladder's `verify` job
runs after every deploy. No DB access; it asserts the API's *contract*
(endpoint shapes, feature-flag values, auth enforcement, a soft date-floor
signal), never data counts. Seven checks, one PASS/WARN/FAIL line each:

| Check | What it asserts |
|---|---|
| `health` | `/api/health` returns `status=ok`, `db=true`; `git_sha`/`env` match if `--expect-sha` given; `sv_tag`/`ui_git_sha` are soft-WARN until SV-12 lands |
| `features` | `/api/features` flag values match the expected per-env table (`tenders`/`city_batyam`/`map_home`) |
| `auth_surface` | `/api/auth/me` and `/api/presentation/deals` both reject unauthenticated requests |
| `floor` | oldest deal returned (authed, sampled) has year ≥ `FLOOR_YEAR` (currently 2021); zero rows is a PASS, not a failure |
| `schema_shape` | `/api/presentation/deals` and `/api/presentation/facets` envelopes match their documented shape |
| `root_twin` | bare unprefixed legacy routes (e.g. `/deals`) do NOT leak JSON — must render the SPA (HTML/404), never uvicorn's raw JSON |
| `strict-hosts` | (only with `--strict-hosts`) sslip alias + raw-IP both refuse HTTPS, `http://<canonical>/` redirects |

Run it manually the same way CI does:
```sh
scripts/validate-box.sh test --expect-sha <shortsha>
```
Credentials: `--user`/`--pass` flags > `$VALIDATE_USER`/`$VALIDATE_PASS` env
> the smoke user below. A login failure WARN-skips the two checks that need
auth (`floor`, `schema_shape`) rather than failing — a missing seed user is
a data-state fact, not a contract violation.

**`--strict-hosts` becomes a real (not advisory) gate post-CI-3-cutover.**
Before the cutover, sslip/raw-IP access is expected to still work (the
dual-host Caddy config), so this flag is opt-in and off by default. The CI
ladder reads the `STRICT_HOSTS` repo variable and only passes
`--strict-hosts` when it's `true` — flip that variable once both boxes are
verified cut over (see `CUTOVER_RUNBOOK_CI-3.md` §5 "Post-cutover").

The old manual smoke recipe still works as a sanity check outside the
script — pointed at the canonical host, not sslip:
```sh
SITE=test.rs-intel.com   # or dev.rs-intel.com once cut over
curl https://$SITE/api/health
# open https://$SITE  → login smoke@dara.local / DaraDemo2026!  → /gush, /deals
# the top-bar chip should read TEST (blue) or DEV (amber) accordingly
```
The smoke user (`smoke@dara.local`) isn't provisioned by the scripts — it
travels inside whichever `pg_dump` you seed from (local or blessed).

## Rollback

**Preferred: redeploy-by-tag via `Actions → Redeploy`.** Dispatch the
`Redeploy` workflow, running it *from the target env's own branch*
(`dev`/`test`/`stg` — dispatching "redeploy test" while sitting on any
other branch fails at the AWS OIDC step, since each env's deploy role trust
policy is branch-bound; the workflow asserts this itself with a clear error
before wasting a build), and pick a tag: `dev` accepts `dev-ok-*` /
`test-ok-*` / `patch-*` / `sv*`; `test` and `stg` accept `test-ok-*` /
`patch-*` only. This re-ships the artifact already built for that sha/tag —
no rebuild, no re-tagging (the ledger still gets a row, `via=redeploy`) —
and reuses the cached S3 build if it's still inside the artifact bucket's
60-day per-prefix expiry (~2 min end to end). If the artifact has aged out
past 60 days there's no cached bundle left to reuse, and the rung falls
through to a full rebuild from that tag's source instead (same rung, just
not the fast path).

**Manual fallback:** `scripts/dev-deploy.sh <dev|test>` from whatever local
tree/branch you need — see "Deploy paths" above. Same CI-outage fallback,
just aimed backward (check out the commit/tag you want to roll back to,
then deploy).

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

## Deviations register (CI/CD build, 2026-07-30)

Accepted deviations/known-debts surfaced while building WOs CI-1..CI-4 (spec:
`PLAN_CICD_GITHUB_SIDEQUEST_2026-07-30.md`). Full ledger, including
parallel-lane watch items and activation-day notes not repeated here:
`CICD_CONCLUSIONS_2026-07-30.md`.

| # | Deviation | Planned / spec'd | Built instead | Why / debt |
|---|---|---|---|---|
| 1 | Artifact retention | keep-last-10 build artifacts | 60-day time-based S3 lifecycle expiry, per env prefix | simpler to express as a Terraform lifecycle rule than count-based retention; means the redeploy-by-tag fast path is bounded by "how recently deployed," not "how many deploys ago" — see Rollback above |
| 2 | CI DB bootstrap | replay the alembic chain from empty in CI (dry-run) | `Base.metadata.create_all` + `alembic stamp head`, then `alembic upgrade head` asserted as a no-op | migration 0001 already does a cumulative `create_all`, so replaying 0002+ from empty hits "relation already exists" — boxes dodge the same way (`SKIP_MIGRATIONS=1` + pg_dump seed). **Real debt**: the chain isn't a from-scratch build path; squash/rebase someday (main dara-v2 lane, not urgent) |
| 3 | Environment gating | GitHub Environments (per-env protection rules, required reviewers) | repo **variables** + ref-form-only OIDC trust subs (`repo:...:ref:refs/heads/<branch>`) | GitHub Environments' protection-rule enforcement is a paid-plan feature; this account is Free-plan, solo-pusher. Branch-bound OIDC trust is the access-control substitute — a workflow run on any other branch or from a fork literally cannot assume the deploy role |
| 4 | Ledger writes | cross-repo ledger commit | orphan `ci-ledger` branch **inside `dara-v2` itself**, `LEDGER.md` | the workflow's `GITHUB_TOKEN` is scoped same-repo only; writing to a separate ledger repo would need a second PAT. `PROMOTIONS.md` (this repo) stays the human ledger — the two never merge, see PROMOTIONS.md's own header note |
| 5 | UI-only pushes | `dara-v2-ui`-side push triggers a deploy directly | manual `workflow_dispatch` of `deploy-dev.yml` | `dara-v2-ui` has no sender workflow yet; a `repository_dispatch` sender would cost one more fine-grained PAT (`actions:write` on `dara-v2`) — deferred, not urgent |
| 6 | Runner hardening | `step-security/harden-runner` on every job | deferred entirely | not wired into any workflow yet — accepted gap, revisit if the ladder gets more eyes on it |
| 7 | Date floor | server-side WHERE floor on served deals | `validate-box.sh`'s `floor` check asserts observed-min-year ≥ `FLOOR_YEAR=2021` only (no server-side enforcement exists anywhere in the codebase) | `STATS_COVERAGE_FLOOR="2021-01"` is a soft UI label, not a query filter. **When the 2025 re-baselining ships** (CEO-gaps map-redesign lane), that lane must bump `env_floor_year()` in `dara-v2/scripts/validate-box.sh` — the check prints the observed min year on every run so the flip is an informed decision, not a surprise |
| 8 | Bare API twins | — | `dara_v2/api.py` mounts several legacy endpoints twice (bare + `/api`-prefixed, e.g. `/deals` + `/api/deals`); the bare twins serve **unauthenticated JSON straight from uvicorn** — the auth middleware only guards `/api/*` | contained today: the api container's port isn't host-published, and Caddy's fallback `handle {}` block routes every non-`/api/*` path to the SPA instead, so the bare route is dark in production. `validate-box.sh`'s `root_twin` check guards this on every deploy. **Main-lane task** (not CI-5): survey consumers of the bare routes, then delete the unprefixed decorators |
| 9 | AWS profile | docs reference `--profile rs-intel` | only the `default` local AWS profile exists (account 502140064073) | either create the named profile, or read every `--profile rs-intel` in these docs as "your `default` profile" until someone does |
| 10 | CI test scope | "scoped pytest on dev, **FULL pytest** on test/stg" (spec §2) | both rungs run an **explicit, verified DB-free file list** (`dara-v2/scripts/ci/run-pytest.sh`), never marker selection | measured in the 2026-07-30 rehearsal, not assumed: `-m "not network and not integration"` collects **1,684 tests**, many of which open a real PostgreSQL connection despite carrying neither marker (a 3-file sample with no DB reachable → 32 failed / 40 errors). Even against the fully-populated local DB, **17 fail** on hardcoded data counts from an older vintage (e.g. `tests/test_subparcel_identity.py:145` wants 3,230 = Hadera-only; the DB now holds 8,147 = Hadera + Bat Yam). The verified list passes **57/57 with no database at all**. **Real debt** (main dara-v2 lane): re-mark the DB-dependent tests `integration`, and de-hardcode the data-count assertions; then CI's list can widen |
| 11 | Box disk hygiene | — | the SSM deploy document now does `rm -rf incoming bundle.tar.gz` + `docker image prune -f` after `compose up` | the rehearsal measured the bundle at **468 MB** (490 MB image). Manual `dev-deploy.sh` deploys are rare, so nobody noticed; **CI deploys on every push to `dev`**, and each `docker load` leaves the previous image dangling — without a prune the box's 40 GB disk fills in a few dozen deploys. `dev-deploy.sh` still has this gap on the manual path (not fixed here; low frequency, and that file is shared with the SV-12 lane) |
