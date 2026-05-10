#!/bin/sh
# Put the staging stack to sleep between demos.
# Scales the ECS service to 0 desired tasks — the container stops, no
# Fargate vCPU/memory charges accrue.
# ALB + NAT + RDS stay up (still billed) so wake-up is ~90 seconds.
# To go cheaper than this, see scripts/deep-sleep.sh — destroys NAT + ECS
# service, drops idle cost to ~$23/mo, wake takes 3-5 min via terraform apply.
set -e

CLUSTER=rs-intelligence-staging
SERVICE=rs-intelligence-staging-api
REGION=eu-west-1

echo "→ scaling $SERVICE to 0 tasks"
aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --desired-count 0 \
    --region "$REGION" \
    --query 'service.{desired:desiredCount,running:runningCount,pending:pendingCount}' \
    --output table

echo ""
echo "💤 staging is going to sleep."
echo "Still billing (~\$65/mo): NAT, ALB, RDS storage, Secrets Manager."
echo "Wake it up with: sh scripts/wake.sh"
