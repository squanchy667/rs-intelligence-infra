#!/usr/bin/env bash
# Seed a box's Postgres (pg_dump → ship → restore). Run after
# scripts/dev-deploy.sh. Idempotent: it resets the public schema and restores
# the full dump (which carries an alembic_version, so the API's startup
# `alembic upgrade head` stays a no-op as long as heads match).
#
# By default, dumps the current LOCAL dara_v2 DB. Pass a second arg (a path to
# an existing .sql.gz dump — e.g. a blessed artifact from
# scripts/make-seed.sh under snapshots/seeds/) to ship that file instead and
# skip the local pg_dump entirely — this is how the shared dev (QA) box should
# always be reseeded (never from a live local pg_dump, which may carry
# mid-campaign local experiments).
#
# Prereqs: local Postgres reachable at localhost:5432 (PGPASSWORD=dara); pg_dump
#          (unless a dump file is given as $2).
# Usage:   scripts/dev-seed.sh <feature|dev> [dump.sql.gz]
set -euo pipefail

# --- box roles --------------------------------------------------------------
# feature → environments/dev2 : the FEATURE box (new work lands here first).
# dev     → environments/dev  : the shared DEV box QA tests on. Blessed
#           dumps only. Directory predates the split — do not rename it; its
#           S3 state key must stay put.
# -----------------------------------------------------------------------------
TARGET="${1:-}"
case "$TARGET" in
  feature) TF_DIR="environments/dev2" ;;
  dev)     TF_DIR="environments/dev" ;;
  *)       echo "usage: dev-seed.sh <feature|dev> [dump.sql.gz]" >&2; exit 1 ;;
esac
DUMP_FILE_ARG="${2:-}"

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEV_TF="$INFRA_DIR/$TF_DIR"
KEY="$INFRA_DIR/${TARGET}_box_key.pem"
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
