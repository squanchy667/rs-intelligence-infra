#!/usr/bin/env bash
# Seed the dev box's Postgres from the current LOCAL dara_v2 DB (pg_dump → ship
# → restore). Run after scripts/dev-deploy.sh. Idempotent: it resets the public
# schema and restores the full dump (which carries alembic_version=0024, so the
# API's startup `alembic upgrade head` stays a no-op).
#
# Prereqs: local Postgres reachable at localhost:5432 (PGPASSWORD=dara); pg_dump.
# Usage:   scripts/dev-seed.sh
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEV_TF="$INFRA_DIR/environments/dev"
KEY="$INFRA_DIR/dev_box_key.pem"
DUMP="/tmp/dara_dev_seed.sql.gz"

LOCAL_PGHOST="${LOCAL_PGHOST:-localhost}"
LOCAL_PGUSER="${LOCAL_PGUSER:-dara}"
LOCAL_PGDB="${LOCAL_PGDB:-dara_v2}"
export PGPASSWORD="${PGPASSWORD:-dara}"

echo "==> Dumping local DB ($LOCAL_PGUSER@$LOCAL_PGHOST/$LOCAL_PGDB)"
pg_dump -h "$LOCAL_PGHOST" -U "$LOCAL_PGUSER" -d "$LOCAL_PGDB" \
  --no-owner --no-privileges | gzip > "$DUMP"
echo "    dump: $(du -h "$DUMP" | cut -f1)"

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
