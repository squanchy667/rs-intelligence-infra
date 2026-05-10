#!/bin/sh
# Wake from deep sleep: terraform apply recreates NAT + route table +
# ECS service. ~3-5 min. Same CloudFront URL, same admin user, same data.
set -e

INFRA="$(cd "$(dirname "$0")/.." && pwd)"
cd "$INFRA"

echo "→ terraform apply (recreates NAT Gateway, private route table, ECS service)"
terraform apply \
    -var-file=environments/staging/terraform.tfvars \
    -auto-approve

echo ""
echo "→ waiting for ECS to stabilise (~2-3 min — NAT + ECS task boot)"
CLUSTER=$(terraform output -raw ecs_cluster_name)
SERVICE=$(terraform output -raw ecs_service_name)
aws ecs wait services-stable \
    --cluster "$CLUSTER" --services "$SERVICE" --region eu-west-1

echo ""
CF_DOMAIN=$(terraform output -raw cloudfront_domain_name)
echo "→ health check at https://$CF_DOMAIN/api/health"
sleep 5
curl -sS -w "\nHTTP %{http_code}\n" "https://$CF_DOMAIN/api/health"

echo ""
echo "✅ staging is awake at https://$CF_DOMAIN"
echo "   (same URL as before — no bookmarks to update)"
