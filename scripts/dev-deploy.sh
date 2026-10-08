#!/usr/bin/env bash
# Deploy the current code to a Lightsail box (artifact-push model): build the
# UI static export + the amd64 API image, ship them + the compose/Caddy
# files to the box, and `docker compose up -d`.
#
# Branch-pinned builds (2026-07-19 model — "an env only ever runs its own
# branch"): every target builds from its own branch tip of both dara-v2 and
# dara-v2-ui via `git archive` into a throwaway build dir — never the working
# tree. `--tree` (dev only) builds whatever is checked out instead.
# CI (`Deploy — dev` / `Deploy — stg`) is the normal path; this script is the
# manual fallback.
#
# Prereqs: terraform applied in the target's TF root; docker buildx; npm.
# Usage:   scripts/dev-deploy.sh <dev|stg> [--yes] [--tree] [--dry-run]
#          (`feature` accepted as a deprecated alias for `dev`)
#   --dry-run  print target / TF dir / key / expected IP / branch and exit —
#              no build, no ssh.
set -euo pipefail

# --- box roles (env model — see DEV.md) ----------------------------------------
# dev → environments/dev2 : Ofek's INTERNAL box. Anything goes — every
#       feature/experiment deploys here first. Historical script-target name:
#       "feature" (still accepted, deprecated alias). TF directory kept as
#       `dev2` — do not rename, its S3 state key must stay put.
# stg → environments/stg  : the box the people who test for us use
#       (https://stg.rs-intel.com) — only `stg`-branch code (ff from dev,
#       gate dev-ok-*) + blessed seed dumps (DEV.md promotion policy).
# test was RETIRED 2026-10-08 (JIG-089): the ladder is dev → stg.
# -----------------------------------------------------------------------------

YES=0
TREE_BUILD=0
DRY_RUN=0
RAW_TARGET=""
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    --tree) TREE_BUILD=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) if [ -z "$RAW_TARGET" ]; then RAW_TARGET="$arg"; fi ;;
  esac
done

case "$RAW_TARGET" in
  feature)
    echo "warning: target 'feature' is a deprecated alias for 'dev' (2026-07-19 env model) — use 'dev' going forward." >&2
    TARGET="dev"
    ;;
  dev) TARGET="dev" ;;
  stg) TARGET="stg" ;;
  test)
    echo "error: target 'test' was retired 2026-10-08 (JIG-089); use stg" >&2
    exit 2
    ;;
  *)
    echo "usage: dev-deploy.sh <dev|stg> [--yes] [--tree] [--dry-run]   (feature = deprecated alias for dev)" >&2
    echo "  builds are BRANCH-PINNED: target 'dev' deploys the 'dev' branch tip, 'stg' the 'stg' tip." >&2
    echo "  --tree  (dev only) build the working tree instead, to deploy an un-merged experiment." >&2
    exit 1
    ;;
esac

case "$TARGET" in
  dev) TF_DIR="environments/dev2"; KEY_NAME="feature_box_key.pem"; EXPECTED_IP="54.155.62.174" ;;
  stg) TF_DIR="environments/stg";  KEY_NAME="stg_box_key.pem";     EXPECTED_IP="34.254.119.146" ;;
esac

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$INFRA_DIR/.." && pwd)"
# Repo paths default to the sibling checkouts, but are overridable so a
# target=dev deploy can build from a WORKTREE instead of the main tree.
# This matters: the main dara-v2 tree is routinely parked on another
# session's branch (corridor scan, SV, map work), and a target=dev deploy
# builds from the working tree — so without this you'd either ship whatever
# that session had checked out, or have to switch branches under them.
#   BE=../dara-v2-cicd scripts/dev-deploy.sh dev
BE="${BE:-$ROOT/dara-v2}"
UI="${UI:-$ROOT/dara-v2-ui}"
DEV_TF="$INFRA_DIR/$TF_DIR"
KEY="$INFRA_DIR/$KEY_NAME"
IMG_TAR="/tmp/dara-api-${TARGET}.tar.gz"

# --- branch-pinned build source ----------------------------------------------
# BOTH targets are branch-pinned (changed 2026-07-30, Ofek): the box always
# runs its own branch's tip, never whatever happened to be checked out.
#   target=dev → archives the `dev` branch tip
#   target=stg → archives the `stg` branch tip
# This is the same contract the CI ladder enforces (deploy-dev.yml builds the
# sha that was pushed to `dev`), so the manual path and CI can no longer
# disagree about what "deployed to dev" means. It also makes the deploy immune
# to which branch a parallel session has the main tree parked on — `git
# archive <branch>` reads the object store, not the worktree.
#
# The workflow this supports: work on a feature branch → merge/push to `dev`
# when it's ready → deploy (or, once CI is live, the push itself deploys).
#
# Escape hatch: `--tree` restores the old target=dev behaviour of building
# whatever is checked out, for deliberately deploying an un-merged experiment.
# It refuses on target=stg — the stg box is never tree-built.
# ------------------------------------------------------------------------------
BUILD_BE="$BE"
BUILD_UI="$UI"
BUILD_TMP=""
# `|| true`: with BUILD_TMP empty (--tree) the [ -n ] test fails, and a
# failing EXIT trap under set -e turns a successful deploy into exit 1.
cleanup() { { [ -n "$BUILD_TMP" ] && rm -rf "$BUILD_TMP"; } || true; }
trap cleanup EXIT

if [ "$TREE_BUILD" = "1" ] && [ "$TARGET" = "stg" ]; then
  echo "error: --tree is not allowed for target=stg — the stg box is always branch-pinned to 'stg'." >&2
  exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "dev-deploy.sh DRY RUN — nothing is built, shipped or connected to"
  echo "  target      = $TARGET"
  echo "  tf dir      = $DEV_TF"
  echo "  ssh key     = $KEY (rewritten from terraform output -raw private_key_pem on a real run)"
  echo "  expected ip = $EXPECTED_IP (asserted against terraform output -raw static_ip before any ssh)"
  if [ "$TREE_BUILD" = "1" ]; then
    echo "  build       = working tree (--tree): dara-v2 $BE, dara-v2-ui $UI"
  else
    echo "  build       = branch-pinned '$TARGET': dara-v2 $(git -C "$BE" rev-parse --short "refs/heads/$TARGET" 2>/dev/null || echo '<no local branch>'), dara-v2-ui $(git -C "$UI" rev-parse --short "refs/heads/$TARGET" 2>/dev/null || echo '<no local branch>')"
  fi
  echo "  host        = $TARGET.rs-intel.com (from domain.env BASE_DOMAIN)"
  exit 0
fi

if [ "$TREE_BUILD" = "1" ]; then
  BE_BRANCH="$(git -C "$BE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  UI_BRANCH="$(git -C "$UI" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  echo "==> target=dev --tree: building the WORKING TREE (dara-v2 on '$BE_BRANCH', dara-v2-ui on '$UI_BRANCH')" >&2
  echo "    this deploys un-merged work; the box's GIT_SHA will not correspond to a 'dev' commit." >&2
else
  for repo in "$BE" "$UI"; do
    if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$TARGET"; then
      echo "error: branch '$TARGET' does not exist in $repo — deploys are branch-pinned and refuse to fall back to the working tree (pass --tree to deploy an un-merged experiment to the dev box)." >&2
      exit 1
    fi
  done
  BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dara-${TARGET}-build.XXXXXX")"
  BUILD_BE="$BUILD_TMP/dara-v2"
  BUILD_UI="$BUILD_TMP/dara-v2-ui"
  mkdir -p "$BUILD_BE" "$BUILD_UI"
  echo "==> target=$TARGET: branch-pinned build — archiving '$TARGET' branch tip of dara-v2 + dara-v2-ui (never the working tree)"
  git -C "$BE" archive "$TARGET" | tar -x -C "$BUILD_BE"
  git -C "$UI" archive "$TARGET" | tar -x -C "$BUILD_UI"
  echo "    dara-v2@$TARGET    → $BUILD_BE   ($(git -C "$BE" rev-parse --short "$TARGET"))"
  echo "    dara-v2-ui@$TARGET → $BUILD_UI   ($(git -C "$UI" rev-parse --short "$TARGET"))"
  echo "==> npm ci in the archived UI tree (no node_modules in a fresh archive)"
  ( cd "$BUILD_UI" && npm ci )
fi

# --- version stamp (pipeline-visibility chip) --------------------------------
# GIT_SHA rides /opt/dara/.env → compose → /api/health "git_sha" → UI chip, so
# every box self-identifies WHICH code it runs, not just which env it is.
# Branch-pinned builds stamp the branch tip — the sha is then a real commit on
# that branch, which is what makes the chip answerable by `git log <branch>`.
# --tree builds stamp the working tree's HEAD, -dirty suffixed when tracked
# files differ (that sha may not exist on any deployable branch — by design).
if [ "$TREE_BUILD" = "1" ]; then
  GIT_SHA="$(git -C "$BE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  git -C "$BE" diff --quiet HEAD -- 2>/dev/null || GIT_SHA="${GIT_SHA}-dirty"
else
  GIT_SHA="$(git -C "$BE" rev-parse --short "$TARGET")"
fi

echo "==> Reading terraform outputs"
IP="$(terraform -chdir="$DEV_TF" output -raw static_ip)"
if [ "$IP" != "$EXPECTED_IP" ]; then
  echo "error: terraform says $TF_DIR static_ip=$IP, expected $EXPECTED_IP for target '$TARGET' — wrong root or the box moved; refusing." >&2
  exit 1
fi
terraform -chdir="$DEV_TF" output -raw private_key_pem > "$KEY"
chmod 600 "$KEY"
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"
# Public hostname — CI-3 canonical-host-only cutover (2026-07-30): each box
# serves EXACTLY ONE hostname; the old space-separated multi-host
# SITE_ADDRESS (sslip + prefixed-sslip + canonical) is retired, Caddy no
# longer accepts it. If domain.env exists in the infra root and sets
# BASE_DOMAIN (e.g. BASE_DOMAIN=rs-intel.com), the canonical host
# <target>.$BASE_DOMAIN is the ONLY SITE_ADDRESS — its A record must point
# at the box's static IP BEFORE deploying (Caddy asks Let's Encrypt for
# exactly that one host now; no DNS = failed issuance, no sslip fallback to
# fall back on). Without domain.env/BASE_DOMAIN, SITE_ADDRESS falls back to
# a single sslip.io host for bootstrap purposes only — see the warning below.
SITE_HOST="${IP//./-}.sslip.io"
PREFIXED_HOST="${TARGET}.${SITE_HOST}"
[ -f "$INFRA_DIR/domain.env" ] && . "$INFRA_DIR/domain.env"
if [ -n "${BASE_DOMAIN:-}" ]; then
  PRIMARY_HOST="${TARGET}.${BASE_DOMAIN}"
  SITE_ADDRESS="$PRIMARY_HOST"
else
  echo "############################################################" >&2
  echo "# WARNING: no domain.env / BASE_DOMAIN found for this box.  #" >&2
  echo "# Falling back to a single sslip.io SITE_ADDRESS:           #" >&2
  echo "#   $PREFIXED_HOST" >&2
  echo "# Canonical-host mode (CI-3) is the EXPECTED shape for real  #" >&2
  echo "# boxes. This sslip fallback exists ONLY to bootstrap a box  #" >&2
  echo "# that has no domain configured yet.                        #" >&2
  echo "############################################################" >&2
  PRIMARY_HOST="$PREFIXED_HOST"
  SITE_ADDRESS="$PREFIXED_HOST"
fi
echo "    box = $IP   host = $PRIMARY_HOST   env = $TARGET"
if [ "$TARGET" = "stg" ] && [ "$YES" != "1" ]; then
  echo "WARNING: target 'stg' = the box people test on ($IP). Manual deploy (CI 'Deploy — stg' is the normal path)." >&2
  echo "    pausing 5s — Ctrl-C to abort, or pass --yes to skip this pause." >&2
  sleep 5
fi

echo "==> Building UI static export (NEXT_PUBLIC_API_URL='' → same-origin /api/)"
( cd "$BUILD_UI" && NEXT_PUBLIC_API_URL="" npm run build )

echo "==> Building API image (linux/amd64) and saving"
( cd "$BUILD_BE" && docker buildx build --platform linux/amd64 -t dara-api:dev --load . )
docker save dara-api:dev | gzip > "$IMG_TAR"

echo "==> Waiting for cloud-init (docker install) on the box"
for _ in $(seq 1 60); do
  if $SSH ubuntu@"$IP" 'test -f /opt/dara/.cloud-init-done' 2>/dev/null; then break; fi
  sleep 5
done

echo "==> Shipping artifacts"
$SSH ubuntu@"$IP" 'mkdir -p /opt/dara/out'
rsync -az -e "$SSH" --delete "$BUILD_UI/out/" ubuntu@"$IP":/opt/dara/out/
rsync -az -e "$SSH" "$BUILD_BE/docker-compose.dev.yml" ubuntu@"$IP":/opt/dara/docker-compose.yml
rsync -az -e "$SSH" "$BUILD_BE/deploy/Caddyfile" ubuntu@"$IP":/opt/dara/Caddyfile
rsync -az -e "$SSH" "$IMG_TAR" ubuntu@"$IP":/opt/dara/dara-api-dev.tar.gz

echo "==> Injecting ENV_LABEL=$TARGET GIT_SHA=$GIT_SHA into /opt/dara/.env (idempotent; other vars e.g. JWT_SECRET untouched)"
$SSH ubuntu@"$IP" "touch /opt/dara/.env; (grep -v -e '^ENV_LABEL=' -e '^GIT_SHA=' /opt/dara/.env || true) > /opt/dara/.env.tmp; { echo 'ENV_LABEL=$TARGET'; echo 'GIT_SHA=$GIT_SHA'; } >> /opt/dara/.env.tmp; mv /opt/dara/.env.tmp /opt/dara/.env"

echo "==> Loading image + starting stack on the box (SITE_ADDRESS='$SITE_ADDRESS' → auto-HTTPS, canonical host only)"
$SSH ubuntu@"$IP" "cd /opt/dara && gunzip -c dara-api-dev.tar.gz | docker load && SITE_ADDRESS='$SITE_ADDRESS' docker compose up -d"

echo "==> Smoke: /api/health (HTTPS may take ~10-30s on first cert issuance)"
sleep 15
# CI-3: probe PRIMARY_HOST only. Non-canonical hosts (sslip aliases, raw IP)
# are expected to FAIL by design post-cutover (Caddy aborts unknown SNI /
# HTTP hosts) — no fallback chain to them here anymore.
curl -fsS "https://$PRIMARY_HOST/api/health" && echo "" \
  || echo "not ready yet on https://$PRIMARY_HOST — check 'docker compose logs caddy' on the box. (sslip/raw-IP fallbacks are intentionally NOT probed: CI-3 canonical-host-only makes them fail by design.)"
echo "==> Done. App: https://$PRIMARY_HOST   (seed data with scripts/dev-seed.sh)"
