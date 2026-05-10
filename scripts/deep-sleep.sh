#!/bin/sh
# Deep sleep: destroy ECS service + NAT Gateway + NAT EIP + the private
# route table that references the NAT. Keeps RDS, CloudFront, ALB, S3,
# Secrets, ECR, VPC + subnets.
#
# Savings vs awake:
#   ECS task       ~$7/mo
#   NAT Gateway   ~$35/mo
#   Total         ~$42/mo → awake $65 → deep-asleep ~$23/mo
#
# URL stays stable (same CloudFront distribution + same ALB DNS).
# /api/* returns 502 while asleep (ALB has no healthy targets).
# Frontend /* continues to work (served from S3).
# RDS is preserved, so no data loss and no re-seed on wake.
#
# Wake: scripts/deep-wake.sh — `terraform apply` recreates NAT + route
# table + ECS service. ~3-5 min.
set -e

INFRA="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INFRA"

echo "────────────────────────────────────────────────────────────"
echo "   DEEP SLEEP — destroys NAT + ECS service + private RT"
echo "   Keeps: RDS, CloudFront, ALB, S3, Secrets, ECR, VPC shell"
echo "────────────────────────────────────────────────────────────"
echo ""
echo "Idle cost after: ~\$23/mo  (vs ~\$65 awake, ~\$1 full hibernate)"
echo "Wake time: 3-5 min via scripts/deep-wake.sh"
echo "URL stability: YES — same CloudFront domain + ALB stays"
echo "Data: preserved (RDS untouched)"
echo ""
printf "Proceed? [type YES]: "
read CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "→ targeted destroy (ECS service, NAT, NAT EIP, private route table + associations)"

terraform destroy \
    -var-file=environments/staging/terraform.tfvars \
    -auto-approve \
    -target=module.ecs.aws_ecs_service.api \
    -target='module.networking.aws_route_table_association.private[0]' \
    -target='module.networking.aws_route_table_association.private[1]' \
    -target=module.networking.aws_route_table.private \
    -target=module.networking.aws_nat_gateway.this \
    -target=module.networking.aws_eip.nat

echo ""
echo "💤 staging is in deep sleep."
echo ""
echo "What's still running: RDS, CloudFront, ALB, S3, Secrets, ECR,"
echo "                      VPC + subnets + public RT + IGW"
echo ""
echo "Heads-up: /api/* requests will 502 until you wake back up."
echo "Wake with: sh scripts/deep-wake.sh"
