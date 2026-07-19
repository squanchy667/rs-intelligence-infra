#!/usr/bin/env bash
# Seed a box's Postgres (pg_dump → ship → restore). Run after
# scripts/dev-deploy.sh. Idempotent: it resets the public schema and restores
# the full dump (which carries an alembic_version, so the API's startup
# `alembic upgrade head` stays a no-op as long as heads match).
#
# By default, dumps the current LOCAL dara_v2 DB. Pass a second arg (a path to
# an existing .sql.gz dump — e.g. a blessed artifact from
# scripts/make-seed.sh under snapshots/seeds/) to ship that file instead and
# skip the local pg_dump entirely — this is how the `test` (review) box should
# always be reseeded (never from a live local pg_dump, which may carry
# mid-campaign local experiments).
#
# Prereqs: local Postgres reachable at localhost:5432 (PGPASSWORD=dara); pg_dump
#          (unless a dump file is given as $2).
# Usage:   scripts/dev-seed.sh <dev|test> [dump.sql.gz] [--yes]
#          (`feature` accepted as a deprecated alias for `dev`)
set -euo pipefail

# --- box roles (2026-07-19 env model — see DEV.md) --------------------------
# dev  → environments/dev2 : Ofek's INTERNAL box (new work lands here first,
#        any local pg_dump is fine). Historical target name: "feature"
#        (still accepted, deprecated alias).
# test → environments/dev  : the REVIEW box. Blessed dumps ONLY. Historical
#        target name: "dev" — CAUTION, meaning FLIPPED under the new model.
#        See the guard below. Directory predates the split — do not rename
#        it; its S3 state key must stay put.
#
# Because the OLD `dev` target meant today's `test` box, a bare `dev`
# invocation can't be told apart from old muscle memory. So target=dev prints
# a one-line notice and pauses 3s (skip with --yes) — enough for a
# habit-typed `dev` to be caught before it seeds the wrong box.
# -----------------------------------------------------------------------------

YES=0
RAW_TARGET=""
DUMP_FILE_ARG=""
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    *)
      if [ -z "$RAW_TARGET" ]; then
        RAW_TARGET="$arg"
      elif [ -z "$DUMP_FILE_ARG" ]; then
        DUMP_FILE_ARG="$arg"
      fi
      ;;
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
    echo "usage: dev-seed.sh <dev|test> [dump.sql.gz] [--yes]   (feature = deprecated alias for dev)" >&2
    exit 1
    ;;
esac

case "$TARGET" in
  dev)  TF_DIR="environments/dev2"; KEY_NAME="feature_box_key.pem" ;;
  test) TF_DIR="environments/dev";  KEY_NAME="dev_box_key.pem" ;;
esac

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEV_TF="$INFRA_DIR/$TF_DIR"
KEY="$INFRA_DIR/$KEY_NAME"
DUMP="/tmp/dara_${TARGET}_seed.sql.gz"

if [ -n "$DUMP_FILE_ARG" ]; then
  if [ ! -f "$DUMP_FILE_ARG" ]; then
    echo "error: dump file not found: $DUMP_FILE_ARG" >&2
    exit 1
  fi
  echo "==> Using existing dump: $DUMP_FILE_ARG"
  cp "$DUMP_FILE_ARG" "$DUMP"
  echo "    dump: $(du -h "$DUMP" | cut -f1)"
else
  LOCAL_PGHOST="${LOCAL_PGHOST:-localhost}"
  LOCAL_PGUSER="${LOCAL_PGUSER:-dara}"
  LOCAL_PGDB="${LOCAL_PGDB:-dara_v2}"
  export PGPASSWORD="${PGPASSWORD:-dara}"

  echo "==> Dumping local DB ($LOCAL_PGUSER@$LOCAL_PGHOST/$LOCAL_PGDB)"
  pg_dump -h "$LOCAL_PGHOST" -U "$LOCAL_PGUSER" -d "$LOCAL_PGDB" \
    --no-owner --no-privileges | gzip > "$DUMP"
  echo "    dump: $(du -h "$DUMP" | cut -f1)"
fi

IP="$(terraform -chdir="$DEV_TF" output -raw static_ip)"
if [ ! -f "$KEY" ]; then
  terraform -chdir="$DEV_TF" output -raw private_key_pem > "$KEY"; chmod 600 "$KEY"
fi
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"

echo "==> Shipping dump to box ($IP)"
rsync -az -e "$SSH" "$DUMP" ubuntu@"$IP":/opt/dara/seed.sql.gz

echo "==> Restoring on the box (stop api → reset schema → restore → start api)"
$SSH ubuntu@"$IP" 'set -e; cd /opt/dara;
  docker compose stop api || true;
  docker compose exec -T postgres psql -U dara -d dara_v2 -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;";
  gunzip -c seed.sql.gz | docker compose exec -T postgres psql -U dara -d dara_v2 >/dev/null;
  docker compose start api'

echo "==> Verifying row counts on the box"
$SSH ubuntu@"$IP" 'cd /opt/dara && docker compose exec -T postgres psql -U dara -d dara_v2 -t -c "SELECT (SELECT count(*) FROM presentation_deals) AS deals, (SELECT count(*) FROM amenities) AS amenities;"'
echo "==> Seed done."
