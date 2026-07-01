#!/bin/sh
# Wake from deep-deep-sleep:
#   1. Read snapshot ID from state/snapshots/latest.json
#   2. terraform apply -var=restore_from_snapshot_id=<id>
#      → recreates RDS-from-snapshot, ALB, NAT, private RT, ECS service
#      → CloudFront origin auto-updates to the new ALB DNS
#   3. Wait for ECS to stabilise
#   4. Health-check via CloudFront
#
# Total time: ~10-15 min (RDS snapshot restore is the long pole; ECS+ALB
# bring-up is ~3 min after RDS is online).
#
# If the AWS-side snapshot is gone (e.g. account closed and you're rebuilding
# in a fresh account), fall back to the offline pg_dump:
#   1. Apply WITHOUT restore_from_snapshot_id (creates an empty RDS)
#   2. gunzip -c snapshots/dumps/<id>.sql.gz | psql $DATABASE_URL
# ECS Exec into the api task and run psql there, since RDS is private-only.
set -eu

INFRA="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INFRA"

LATEST="state/snapshots/latest.json"
TFVARS="environments/staging/terraform.tfvars"

if [ ! -f "$LATEST" ]; then
    echo "ERROR: $LATEST not found."
    echo "Either deep-deep-sleep was never run, or the state dir was wiped."
    echo "If you have a snapshot ID manually, run:"
    echo "  terraform apply -var-file=$TFVARS -var=restore_from_snapshot_id=<id>"
    exit 1
fi

# Extract snapshot_id without requiring jq (small, well-known JSON shape).
SNAPSHOT_ID=$(awk -F'"' '/"snapshot_id"/ {print $4; exit}' "$LATEST")
SNAPSHOT_ARN=$(awk -F'"' '/"snapshot_arn"/ {print $4; exit}' "$LATEST")
S3_DUMP=$(awk -F'"' '/"s3_uri"/ {print $4; exit}' "$LATEST")
LOCAL_DUMP=$(awk -F'"' '/"local_path"/ {print $4; exit}' "$LATEST")

if [ -z "$SNAPSHOT_ID" ]; then
    echo "ERROR: could not read snapshot_id from $LATEST"
    exit 1
fi

echo "────────────────────────────────────────────────────────────"
echo "   DEEP-DEEP WAKE — restoring from manual snapshot"
echo "────────────────────────────────────────────────────────────"
echo "Snapshot:     $SNAPSHOT_ID"
echo "S3 dump:      $S3_DUMP"
echo "Local dump:   $LOCAL_DUMP  (DR fallback only)"
echo ""
echo "What happens: terraform apply recreates RDS-from-snapshot, ALB,"
echo "              NAT, private route table, ECS service. CloudFront"
echo "              origin auto-updates to the new ALB DNS."
echo ""
echo "Time:         10-15 min. URL stays the same."
echo ""

# ── Verify snapshot still exists ─────────────────────────────────────

REGION=$(awk -F'"' '/"region"/ {print $4; exit}' "$LATEST")
REGION="${REGION:-eu-west-1}"

echo "→ verifying snapshot $SNAPSHOT_ID exists in $REGION"
SNAPSHOT_STATUS=$(aws rds describe-db-snapshots \
    --db-snapshot-identifier "$SNAPSHOT_ID" \
    --region "$REGION" \
    --query 'DBSnapshots[0].Status' \
    --output text 2>/dev/null || echo "MISSING")

if [ "$SNAPSHOT_STATUS" = "MISSING" ] || [ "$SNAPSHOT_STATUS" = "None" ]; then
    echo ""
    echo "⚠ Snapshot $SNAPSHOT_ID not found in AWS."
    echo "  Falling back to offline pg_dump restore is a 2-step manual flow:"
    echo "    1. sh scripts/deep-wake.sh   # wakes WITHOUT snapshot — empty DB"
    echo "    2. ECS-Exec into the api task, run:"
    echo "         gunzip -c /path/to/$LOCAL_DUMP | psql \$DATABASE_URL"
    echo "  (Local dump must be uploaded into the task first; or s3 cp from"
    echo "   $S3_DUMP if it still exists.)"
    exit 1
fi
echo "  status: $SNAPSHOT_STATUS"

if [ "$SNAPSHOT_STATUS" != "available" ]; then
    echo "ERROR: snapshot status is '$SNAPSHOT_STATUS', expected 'available'."
    exit 1
fi

# ── terraform apply with snapshot restore var ───────────────────────

echo ""
echo "→ terraform apply -var=restore_from_snapshot_id=$SNAPSHOT_ID"
echo "  (recreates NAT+private RT+ALB+RDS-from-snapshot+ECS service)"
echo ""

terraform apply \
    -var-file="$TFVARS" \
    -var="restore_from_snapshot_id=$SNAPSHOT_ID" \
    -auto-approve

# ── Wait for ECS to stabilise ────────────────────────────────────────

echo ""
echo "→ waiting for ECS service to stabilise (ALB health + 2 consecutive checks)"
CLUSTER=$(terraform output -raw ecs_cluster_name)
SERVICE=$(terraform output -raw ecs_service_name)
aws ecs wait services-stable \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --region "$REGION"

# ── Health check ─────────────────────────────────────────────────────

echo ""
CF_DOMAIN=$(terraform output -raw cloudfront_domain_name)
echo "→ health check at https://$CF_DOMAIN/api/health"
sleep 5
HTTP_CODE=$(curl -sS -o /tmp/dd-wake-health.txt -w "%{http_code}" "https://$CF_DOMAIN/api/health" || echo "000")
echo "HTTP $HTTP_CODE"
if [ -s /tmp/dd-wake-health.txt ]; then
    head -c 500 /tmp/dd-wake-health.txt
    echo ""
fi

if [ "$HTTP_CODE" = "200" ]; then
    echo ""
    echo "✅ staging is awake at https://$CF_DOMAIN"
    echo "   (data restored from $SNAPSHOT_ID)"
else
    echo ""
    echo "⚠ health check returned $HTTP_CODE — CloudFront origin update may still"
    echo "  be propagating (5-10 min more). Re-run this script's health check:"
    echo "    curl -sS -w '\nHTTP %{http_code}\n' https://$CF_DOMAIN/api/health"
fi
