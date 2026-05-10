#!/bin/sh
# Wake the staging stack back up after scripts/sleep.sh put it to 0 tasks.
set -e

CLUSTER=rs-intelligence-staging
SERVICE=rs-intelligence-staging-api
REGION=eu-west-1
INFRA="$(cd "$(dirname "$0")/.." && pwd)"

echo "→ scaling $SERVICE to 1 task"
aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --desired-count 1 \
    --region "$REGION" \
    --query 'service.{desired:desiredCount,running:runningCount,pending:pendingCount}' \
    --output table

echo ""
echo "→ waiting for task to be stable (ALB health + 2 consecutive checks)..."
aws ecs wait services-stable \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --region "$REGION"

echo ""
CF_DOMAIN=$(cd "$INFRA" && terraform output -raw cloudfront_domain_name)
echo "→ health check via CloudFront"
sleep 3
curl -sS -w "\nHTTP %{http_code}\n" "https://$CF_DOMAIN/api/health"

echo ""
echo "✅ staging is awake at https://$CF_DOMAIN"
