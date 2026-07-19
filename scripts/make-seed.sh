#!/usr/bin/env bash
# Cut a "blessed" seed dump artifact from the current LOCAL dara_v2 DB.
#
# Blessed dumps are the ONLY data source the `test` (review) box should ever
# be reseeded from (scripts/dev-seed.sh test <dump.sql.gz>) — never a live
# local pg_dump, which may carry mid-campaign local experiments. Run this
# whenever local data reaches a state worth promoting, then hand the printed
# path to `dev-seed.sh test`.
#
# Prereqs: local Postgres reachable at localhost:5432 (PGPASSWORD=dara); pg_dump; psql.
# Usage:   scripts/make-seed.sh
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SEEDS_DIR="$INFRA_DIR/snapshots/seeds"
MANIFEST="$SEEDS_DIR/MANIFEST.txt"

LOCAL_PGHOST="${LOCAL_PGHOST:-localhost}"
LOCAL_PGPORT="${LOCAL_PGPORT:-5432}"
LOCAL_PGUSER="${LOCAL_PGUSER:-dara}"
LOCAL_PGDB="${LOCAL_PGDB:-dara_v2}"
export PGPASSWORD="${PGPASSWORD:-dara}"

PSQL=(psql -h "$LOCAL_PGHOST" -p "$LOCAL_PGPORT" -U "$LOCAL_PGUSER" -d "$LOCAL_PGDB")

mkdir -p "$SEEDS_DIR"

echo "==> Reading alembic head"
ALEMBIC_HEAD="$("${PSQL[@]}" -t -c "SELECT version_num FROM alembic_version;" | tr -d '[:space:]')"
if [ -z "$ALEMBIC_HEAD" ]; then
  echo "error: could not read alembic_version from $LOCAL_PGUSER@$LOCAL_PGHOST/$LOCAL_PGDB" >&2
  exit 1
fi
echo "    alembic head: $ALEMBIC_HEAD"

DATE_STAMP="$(date +%F)"
OUT_FILE="$SEEDS_DIR/dara_v2_${DATE_STAMP}_${ALEMBIC_HEAD}.sql.gz"

echo "==> Dumping local DB ($LOCAL_PGUSER@$LOCAL_PGHOST/$LOCAL_PGDB)"
pg_dump -h "$LOCAL_PGHOST" -p "$LOCAL_PGPORT" -U "$LOCAL_PGUSER" -d "$LOCAL_PGDB" \
  --no-owner --no-privileges | gzip > "$OUT_FILE"
echo "    dump: $(du -h "$OUT_FILE" | cut -f1)"

echo "==> Gathering provenance"
DEALS_BY_CITY="$("${PSQL[@]}" -t -c "SELECT city_id, count(*) FROM deals GROUP BY city_id ORDER BY city_id;" | sed '/^\s*$/d' | tr -s ' ' | sed 's/^ //')"
PRESENTATION_DEALS_COUNT="$("${PSQL[@]}" -t -c "SELECT count(*) FROM presentation_deals;" | tr -d '[:space:]')"

{
  echo "== $(date -u +"%Y-%m-%dT%H:%M:%SZ") =="
  echo "alembic_head: $ALEMBIC_HEAD"
  echo "deals by city_id:"
  echo "$DEALS_BY_CITY" | sed 's/^/  /'
  echo "presentation_deals: $PRESENTATION_DEALS_COUNT"
  echo "file: $(basename "$OUT_FILE")"
  echo ""
} >> "$MANIFEST"

echo "==> Manifest updated: $MANIFEST"
echo "$OUT_FILE"
