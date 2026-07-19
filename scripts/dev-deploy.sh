#!/usr/bin/env bash
# Deploy the current code to a Lightsail box (artifact-push model): build the
# UI static export + the amd64 API image, ship them + the compose/Caddy
# files to the box, and `docker compose up -d`.
#
# Branch-pinned builds (2026-07-19 model — "an env only ever runs its own
# branch"): target=test ALWAYS builds from the `test` branch tip of both
# dara-v2 and dara-v2-ui via `git archive` into a throwaway build dir — never
# the working tree, which sits on `dev`. target=dev keeps building from
# whatever's currently checked out (Ofek's sandbox — any local tree, any
# time), but warns if that tree isn't on `dev`.
#
# Prereqs: terraform applied in the target's TF root; docker buildx; npm.
# Usage:   scripts/dev-deploy.sh <dev|test> [--yes]
#          (`feature` accepted as a deprecated alias for `dev`)
set -euo pipefail

# --- box roles (2026-07-19 env model — see DEV.md) --------------------------
# dev  → environments/dev2 : Ofek's INTERNAL box. Anything goes — every
#        feature/experiment deploys here first, from any local tree.
#        Historical script-target name: "feature" (still accepted, deprecated
#        alias). TF directory kept as `dev2` — do not rename, its S3 state
#        key must stay put.
# test → environments/dev  : the REVIEW box (https://54-195-65-131.sslip.io) —
#        only gets cherry-picked `test`-branch code + blessed seed dumps (see
#        DEV.md promotion policy). TF directory predates the split and must
#        not be renamed either — its S3 state key must stay put.
#        Historical script-target name: "dev" — CAUTION, meaning FLIPPED
#        under the new model. See the guard below.
#
# Because the OLD `dev` target meant today's `test` box, a bare `dev`
# invocation can't be told apart from old muscle memory. So target=dev prints
# a one-line notice and pauses 3s (skip with --yes) — enough for a
# habit-typed `dev` to be caught before it deploys to the wrong box.
# -----------------------------------------------------------------------------

YES=0
RAW_TARGET=""
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    *) if [ -z "$RAW_TARGET" ]; then RAW_TARGET="$arg"; fi ;;
  esac
done

case "$RAW_TARGET" in
  feature)
    echo "warning: target 'feature' is a deprecated alias for 'dev' (2026-07-19 env model) — use 'dev' going forward." >&2
    TARGET="dev"
    ;;
  dev)
    echo "NOTE: target 'dev' = the INTERNAL box (environments/dev2) under the 2026-07-19 model; the review box is now 'test'." >&2
    if [ "$YES" != "1" ]; then
      echo "    pausing 3s in case this was a habit-typed old-vocabulary 'dev' (= today's 'test') — Ctrl-C to abort, or pass --yes to skip this pause." >&2
      sleep 3
    fi
    TARGET="dev"
    ;;
  test)
    TARGET="test"
    ;;
  *)
    echo "usage: dev-deploy.sh <dev|test> [--yes]   (feature = deprecated alias for dev)" >&2
    exit 1
    ;;
esac

case "$TARGET" in
  dev)  TF_DIR="environments/dev2"; KEY_NAME="feature_box_key.pem" ;;
  test) TF_DIR="environments/dev";  KEY_NAME="dev_box_key.pem" ;;
esac

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$INFRA_DIR/.." && pwd)"
BE="$ROOT/dara-v2"
UI="$ROOT/dara-v2-ui"
DEV_TF="$INFRA_DIR/$TF_DIR"
KEY="$INFRA_DIR/$KEY_NAME"
IMG_TAR="/tmp/dara-api-${TARGET}.tar.gz"

# --- branch-pinned build source ----------------------------------------------
# test: never the working tree — archive the `test` branch of both repos into
#       a throwaway dir. dev: the working tree, with a non-blocking warning if
#       it isn't on `dev` (Ofek may deliberately deploy an experiment).
# ------------------------------------------------------------------------------
BUILD_BE="$BE"
BUILD_UI="$UI"
BUILD_TMP=""
# `|| true`: with BUILD_TMP empty (target=dev) the [ -n ] test fails, and a
# failing EXIT trap under set -e turns a successful deploy into exit 1.
cleanup() { { [ -n "$BUILD_TMP" ] && rm -rf "$BUILD_TMP"; } || true; }
trap cleanup EXIT

if [ "$TARGET" = "test" ]; then
  for repo in "$BE" "$UI"; do
    if ! git -C "$repo" show-ref --verify --quiet "refs/heads/test"; then
      echo "error: branch 'test' does not exist in $repo — target=test builds are branch-pinned and refuse to fall back to the working tree." >&2
      exit 1
    fi
  done
  BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dara-test-build.XXXXXX")"
  BUILD_BE="$BUILD_TMP/dara-v2"
  BUILD_UI="$BUILD_TMP/dara-v2-ui"
  mkdir -p "$BUILD_BE" "$BUILD_UI"
  echo "==> target=test: branch-pinned build — archiving 'test' branch tip of dara-v2 + dara-v2-ui (never the working tree, which sits on 'dev')"
  git -C "$BE" archive test | tar -x -C "$BUILD_BE"
  git -C "$UI" archive test | tar -x -C "$BUILD_UI"
  echo "    dara-v2@test    → $BUILD_BE   ($(git -C "$BE" rev-parse --short test))"
  echo "    dara-v2-ui@test → $BUILD_UI   ($(git -C "$UI" rev-parse --short test))"
  echo "==> npm ci in the archived UI tree (no node_modules in a fresh archive)"
  ( cd "$BUILD_UI" && npm ci )
else
  BE_BRANCH="$(git -C "$BE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  UI_BRANCH="$(git -C "$UI" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  if [ "$BE_BRANCH" != "dev" ] || [ "$UI_BRANCH" != "dev" ]; then
    echo "WARNING: target=dev builds from the CURRENT working tree, but dara-v2 is on '$BE_BRANCH' and dara-v2-ui is on '$UI_BRANCH' (expected 'dev' on both). Proceeding — dev deploys are tree-based, not branch-pinned." >&2
  fi
fi

echo "==> Reading terraform outputs"
IP="$(terraform -chdir="$DEV_TF" output -raw static_ip)"
terraform -chdir="$DEV_TF" output -raw private_key_pem > "$KEY"
chmod 600 "$KEY"
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"
# Public hostnames via sslip.io (resolves the embedded IP → Caddy auto-HTTPS).
# Two aliases per box: the bare-IP host (stable across redeploys) and a
# target-prefixed host (dev.<ip>.sslip.io / test.<ip>.sslip.io) — the
# prefixed name is canonical (unambiguous at a glance); the bare-IP host
# remains a fallback. Both are static-IP-derived, so a recreate just works.
SITE_HOST="${IP//./-}.sslip.io"
PREFIXED_HOST="${TARGET}.${SITE_HOST}"
SITE_ADDRESS="$PREFIXED_HOST $SITE_HOST"
echo "    box = $IP   host = $PREFIXED_HOST (+ $SITE_HOST)   env = $TARGET"

echo "==> Building UI static export (NEXT_PUBLIC_API_URL='' → same-origin /api/)"
( cd "$BUILD_UI" && NEXT_PUBLIC_API_URL="" npm run build )

echo "==> Building API image (linux/amd64) and saving"
( cd "$BUILD_BE" && docker buildx build --platform linux/amd64 -t dara-api:dev --load . )
docker save dara-api:dev | gzip > "$IMG_TAR"

echo "==> Waiting for cloud-init (docker install) on the box"
for i in $(seq 1 60); do
  if $SSH ubuntu@"$IP" 'test -f /opt/dara/.cloud-init-done' 2>/dev/null; then break; fi
  sleep 5
done

echo "==> Shipping artifacts"
$SSH ubuntu@"$IP" 'mkdir -p /opt/dara/out'
rsync -az -e "$SSH" --delete "$BUILD_UI/out/" ubuntu@"$IP":/opt/dara/out/
rsync -az -e "$SSH" "$BUILD_BE/docker-compose.dev.yml" ubuntu@"$IP":/opt/dara/docker-compose.yml
rsync -az -e "$SSH" "$BUILD_BE/deploy/Caddyfile" ubuntu@"$IP":/opt/dara/Caddyfile
rsync -az -e "$SSH" "$IMG_TAR" ubuntu@"$IP":/opt/dara/dara-api-dev.tar.gz

echo "==> Injecting ENV_LABEL=$TARGET into /opt/dara/.env (idempotent; other vars e.g. JWT_SECRET untouched)"
$SSH ubuntu@"$IP" "touch /opt/dara/.env; (grep -v '^ENV_LABEL=' /opt/dara/.env || true) > /opt/dara/.env.tmp; echo 'ENV_LABEL=$TARGET' >> /opt/dara/.env.tmp; mv /opt/dara/.env.tmp /opt/dara/.env"

echo "==> Loading image + starting stack on the box (SITE_ADDRESS='$SITE_ADDRESS' → auto-HTTPS on both hostnames)"
$SSH ubuntu@"$IP" "cd /opt/dara && gunzip -c dara-api-dev.tar.gz | docker load && SITE_ADDRESS='$SITE_ADDRESS' docker compose up -d"

echo "==> Smoke: /api/health (HTTPS may take ~10-30s on first cert issuance)"
sleep 15
curl -fsS "https://$PREFIXED_HOST/api/health" && echo "" \
  || curl -fsS "https://$SITE_HOST/api/health" && echo "" \
  || curl -fsS "http://$IP/api/health" && echo " (http; cert still provisioning)" \
  || echo "not ready yet — check 'docker compose logs caddy' on the box"
echo "==> Done. App: https://$PREFIXED_HOST   (also https://$SITE_HOST)   (seed data with scripts/dev-seed.sh)"
