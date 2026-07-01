#!/bin/sh
# Deep-DEEP sleep: maximum-savings idle state for prolonged dev.
#
# What it does, in order:
#   1. Run a one-off Fargate task that pg_dumps RDS to s3://<seed>/snapshots/
#   2. Download that dump locally to snapshots/dumps/<id>.sql.gz (offline DR
#      copy — survives an AWS account closure)
#   3. Take a manual RDS snapshot (used by deep-deep-wake.sh for fast restore)
#   4. Write state/snapshots/<id>.json + state/snapshots/latest.json
#   5. Targeted destroy of: ECS service, NAT, NAT EIP, private route table,
#      ALB + listener + target group, RDS instance.
#
# What stays: VPC + subnets + IGW + public RT, security groups, Secrets
# Manager, ECR, S3 (frontend + seed), CloudFront, parameter group, subnet
# group, IAM roles. CloudFront URL stays the same on wake.
#
# Idle cost estimate after this:
#   RDS snapshot storage    ~$2/mo (20 GB @ $0.095/GB)
#   S3 (frontend + dump)    ~$0.50/mo
#   Secrets Manager         ~$1/mo (3 secrets @ $0.40)
#   CloudFront              $0 idle
#   Total                   ~$3-4/mo
#
# vs deep-sleep ~$23/mo, vs awake ~$65/mo.
#
# Wake time: ~10-15 min (RDS snapshot restore is the long pole), via
# scripts/deep-deep-wake.sh.
#
# URL during sleep: frontend (S3+CloudFront) keeps working. /api/* returns
# 502 (no ALB target). On wake the URL is unchanged.
set -eu

INFRA="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INFRA"

DUMP_MAX_MB="${DEEP_DEEP_DUMP_MAX_MB:-50}"
TFVARS="environments/staging/terraform.tfvars"

# ── Pre-flight ────────────────────────────────────────────────────────

echo "────────────────────────────────────────────────────────────"
echo "   DEEP-DEEP SLEEP — destroys RDS + ALB + NAT + ECS + private RT"
echo "   Keeps:  RDS snapshot, CloudFront, S3, Secrets, ECR, VPC shell"
echo "   Local:  snapshots/dumps/<ts>.sql.gz (offline DR copy)"
echo "────────────────────────────────────────────────────────────"
echo ""
echo "Idle cost after: ~\$3-4/mo  (vs ~\$23 deep-sleep, ~\$65 awake)"
echo "Wake time:       10-15 min via scripts/deep-deep-wake.sh"
echo "URL stability:   YES — same CloudFront domain"
echo "Data:            preserved 2 ways — RDS snapshot + offline pg_dump"
echo ""
printf "Proceed? [type YES]: "
read CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

# ── Pull infra refs from terraform ───────────────────────────────────

echo ""
echo "→ reading current infra state from terraform"
REGION=$(terraform output -raw aws_region)
CLUSTER=$(terraform output -raw ecs_cluster_name)
SUBNET_IDS=$(terraform output -json private_subnet_ids | tr -d '[]" \n' | sed 's/,/,/g')
ECS_SG=$(terraform output -raw ecs_security_group_id)
TASK_EXEC_ROLE=$(terraform output -raw ecs_task_execution_role_arn)
TASK_ROLE=$(terraform output -raw ecs_task_role_arn)
DATABASE_URL_SECRET=$(terraform output -raw database_url_secret_arn)
LOG_GROUP=$(terraform output -raw ecs_log_group_name)
RDS_ID=$(terraform output -raw rds_endpoint | sed 's/\..*//')
# seed_bucket_arn comes from tfvars (not exposed as output) — extract bucket name
SEED_BUCKET_ARN=$(awk -F'"' '/^seed_bucket_arn/ {print $2}' "$TFVARS")
SEED_BUCKET="${SEED_BUCKET_ARN##*:::}"

if [ -z "$SEED_BUCKET" ]; then
    echo "ERROR: seed_bucket_arn not set in $TFVARS — required for snapshot dumps."
    exit 1
fi

TS=$(date -u +%Y%m%d-%H%M%S)
DUMP_KEY="snapshots/${TS}.sql.gz"
SNAPSHOT_ID="rs-intelligence-staging-ddsleep-${TS}"
TASK_FAMILY="rs-intelligence-staging-pgdump"
LOCAL_DUMP="snapshots/dumps/${TS}.sql.gz"
STATE_FILE="state/snapshots/${TS}.json"

echo "  cluster:        $CLUSTER"
echo "  region:         $REGION"
echo "  RDS:            $RDS_ID"
echo "  seed bucket:    s3://$SEED_BUCKET"
echo "  snapshot ID:    $SNAPSHOT_ID"
echo "  dump key:       $DUMP_KEY"

# ── Step 1: register one-off pg_dump task definition ─────────────────

echo ""
echo "→ registering one-off pg_dump task definition ($TASK_FAMILY)"

# Inline awscli install + pg_dump | gzip | aws s3 cp -. ARM64 to match the
# rest of the cluster. 0.5 vCPU / 1 GB is enough for a streaming dump even on
# multi-GB DBs (memory is for pg_dump's catalog snapshot, not row data).
DUMP_CMD='set -euo pipefail
apt-get update -qq
apt-get install -y -qq curl unzip ca-certificates >/dev/null
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install -i /usr/local/aws-cli -b /usr/local/bin >/dev/null
echo "[dumper] pg_dump → s3://'"$SEED_BUCKET"'/'"$DUMP_KEY"'"
pg_dump --no-owner --no-acl --format=plain "$DATABASE_URL" \
  | gzip -9 \
  | aws s3 cp - "s3://'"$SEED_BUCKET"'/'"$DUMP_KEY"'" --region "'"$REGION"'" --no-progress
echo "[dumper] DONE"'

DUMP_TASKDEF=$(cat <<JSON
{
  "family": "$TASK_FAMILY",
  "cpu": "512",
  "memory": "1024",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "executionRoleArn": "$TASK_EXEC_ROLE",
  "taskRoleArn": "$TASK_ROLE",
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  },
  "containerDefinitions": [
    {
      "name": "dumper",
      "image": "postgres:16-bookworm",
      "essential": true,
      "entryPoint": ["bash", "-c"],
      "command": [$(printf '%s' "$DUMP_CMD" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')],
      "secrets": [
        { "name": "DATABASE_URL", "valueFrom": "$DATABASE_URL_SECRET" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$LOG_GROUP",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "pgdump"
        }
      }
    }
  ]
}
JSON
)

TASKDEF_ARN=$(echo "$DUMP_TASKDEF" \
    | aws ecs register-task-definition \
        --cli-input-json file:///dev/stdin \
        --region "$REGION" \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text)
echo "  registered: $TASKDEF_ARN"

# ── Step 2: run the dump task ────────────────────────────────────────

echo ""
echo "→ launching dump task (~3 min: apt+awscli install, then pg_dump)"

TASK_ARN=$(aws ecs run-task \
    --cluster "$CLUSTER" \
    --launch-type FARGATE \
    --task-definition "$TASKDEF_ARN" \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$ECS_SG],assignPublicIp=DISABLED}" \
    --region "$REGION" \
    --query 'tasks[0].taskArn' \
    --output text)
echo "  task: $TASK_ARN"

aws ecs wait tasks-stopped \
    --cluster "$CLUSTER" \
    --tasks "$TASK_ARN" \
    --region "$REGION"

EXIT_CODE=$(aws ecs describe-tasks \
    --cluster "$CLUSTER" \
    --tasks "$TASK_ARN" \
    --region "$REGION" \
    --query 'tasks[0].containers[0].exitCode' \
    --output text)

# Always deregister the temp task def — regardless of dump outcome — so we
# don't leak revisions.
aws ecs deregister-task-definition \
    --task-definition "$TASKDEF_ARN" \
    --region "$REGION" >/dev/null

if [ "$EXIT_CODE" != "0" ]; then
    REASON=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
                --region "$REGION" --query 'tasks[0].stoppedReason' --output text)
    echo "ERROR: dumper task exited with code $EXIT_CODE ($REASON)."
    echo "Check logs: aws logs tail $LOG_GROUP --since 10m --region $REGION"
    echo "Aborting — RDS not snapshotted, infra still up."
    exit 1
fi
echo "  ✓ dump uploaded"

# ── Step 3: download dump locally ────────────────────────────────────

echo ""
echo "→ downloading dump to $LOCAL_DUMP"
mkdir -p snapshots/dumps
aws s3 cp "s3://$SEED_BUCKET/$DUMP_KEY" "$LOCAL_DUMP.tmp" --region "$REGION" --no-progress
mv "$LOCAL_DUMP.tmp" "$LOCAL_DUMP"

DUMP_SIZE_BYTES=$(stat -f%z "$LOCAL_DUMP" 2>/dev/null || stat -c%s "$LOCAL_DUMP")
DUMP_SIZE_MB=$((DUMP_SIZE_BYTES / 1024 / 1024))
echo "  $DUMP_SIZE_MB MB ($DUMP_SIZE_BYTES bytes)"

if [ "$DUMP_SIZE_MB" -gt "$DUMP_MAX_MB" ]; then
    mv "$LOCAL_DUMP" "${LOCAL_DUMP}.skipped"
    echo "  ⚠ dump > ${DUMP_MAX_MB} MB — renamed to .skipped (gitignored)."
    echo "    To commit anyway: mv ${LOCAL_DUMP}.skipped $LOCAL_DUMP && git add -f $LOCAL_DUMP"
    echo "    The S3 copy at s3://$SEED_BUCKET/$DUMP_KEY is your durable copy."
    LOCAL_DUMP_FINAL="${LOCAL_DUMP}.skipped"
    LOCAL_COMMITTED=false
else
    LOCAL_DUMP_FINAL="$LOCAL_DUMP"
    LOCAL_COMMITTED=true
fi

# ── Step 4: take RDS snapshot ────────────────────────────────────────

echo ""
echo "→ taking RDS snapshot $SNAPSHOT_ID (used by deep-deep-wake)"
SNAPSHOT_ARN=$(aws rds create-db-snapshot \
    --db-instance-identifier "$RDS_ID" \
    --db-snapshot-identifier "$SNAPSHOT_ID" \
    --region "$REGION" \
    --tags "Key=Project,Value=rs-intelligence" \
           "Key=Environment,Value=staging" \
           "Key=Purpose,Value=deep-deep-sleep" \
    --query 'DBSnapshot.DBSnapshotArn' \
    --output text)
echo "  $SNAPSHOT_ARN"

echo "  waiting for snapshot to be available (~3-5 min)..."
aws rds wait db-snapshot-available \
    --db-snapshot-identifier "$SNAPSHOT_ID" \
    --region "$REGION"
echo "  ✓ snapshot available"

# ── Step 5: write state JSON ─────────────────────────────────────────

ENGINE_VERSION=$(awk -F'"' '/^  default *= *"16/ {print $2}' modules/database/variables.tf | head -1)
mkdir -p state/snapshots

cat > "$STATE_FILE" <<JSON
{
  "id": "$TS",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "rds": {
    "snapshot_id": "$SNAPSHOT_ID",
    "snapshot_arn": "$SNAPSHOT_ARN",
    "source_db_identifier": "$RDS_ID",
    "engine_version": "$ENGINE_VERSION",
    "region": "$REGION"
  },
  "dump": {
    "s3_uri": "s3://$SEED_BUCKET/$DUMP_KEY",
    "local_path": "$LOCAL_DUMP_FINAL",
    "size_bytes": $DUMP_SIZE_BYTES,
    "committed_to_repo": $LOCAL_COMMITTED
  }
}
JSON

cp "$STATE_FILE" state/snapshots/latest.json
echo ""
echo "→ wrote $STATE_FILE (and latest.json pointer)"

# ── Step 6: targeted destroy ─────────────────────────────────────────

echo ""
echo "→ targeted destroy: RDS, ALB (+listener+TG), ECS service, NAT, NAT EIP, private RT"

terraform destroy \
    -var-file="$TFVARS" \
    -auto-approve \
    -target=module.database.aws_db_instance.this \
    -target=module.alb.aws_lb_listener.http \
    -target=module.alb.aws_lb_target_group.api \
    -target=module.alb.aws_lb.this \
    -target=module.ecs.aws_ecs_service.api \
    -target='module.networking.aws_route_table_association.private[0]' \
    -target='module.networking.aws_route_table_association.private[1]' \
    -target=module.networking.aws_route_table.private \
    -target=module.networking.aws_nat_gateway.this \
    -target=module.networking.aws_eip.nat

echo ""
echo "💤💤 staging is in deep-deep sleep."
echo ""
echo "Snapshot:    $SNAPSHOT_ID  (AWS, used by wake)"
echo "Local dump:  $LOCAL_DUMP_FINAL"
echo "S3 dump:     s3://$SEED_BUCKET/$DUMP_KEY"
echo "State file:  $STATE_FILE"
echo ""
echo "Wake with:   sh scripts/deep-deep-wake.sh"
echo ""
echo "Heads-up: /api/* returns 502 until you wake. Frontend (S3) keeps working."
