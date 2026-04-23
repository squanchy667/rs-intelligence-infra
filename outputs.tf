# Root outputs. Populated as subsequent Terraform tasks wire in their modules:
#   T052 — networking (VPC, subnets, SGs)
#   T053 — ECR repository URL
#   T056 — RDS endpoint
#   T057 — ALB DNS name
#   T058 — CloudFront domain, S3 bucket
#   T059 — Secrets Manager ARNs
#   T060 — ECS cluster + service

output "project_name" {
  value       = var.project_name
  description = "Project identifier used as a resource prefix."
}

output "environment" {
  value       = var.environment
  description = "Deployment environment."
}

output "aws_region" {
  value       = var.aws_region
  description = "AWS region."
}

# ── Networking (T052) ────────────────────────────────────────────────

output "vpc_id" {
  value       = module.networking.vpc_id
  description = "VPC ID."
}

output "public_subnet_ids" {
  value       = module.networking.public_subnet_ids
  description = "Public subnets (ALB, NAT)."
}

output "private_subnet_ids" {
  value       = module.networking.private_subnet_ids
  description = "Private subnets (ECS, RDS)."
}

output "alb_security_group_id" {
  value       = module.networking.alb_security_group_id
  description = "ALB security group."
}

output "ecs_security_group_id" {
  value       = module.networking.ecs_security_group_id
  description = "ECS security group."
}

output "rds_security_group_id" {
  value       = module.networking.rds_security_group_id
  description = "RDS security group."
}

# ── ECR (T053) ───────────────────────────────────────────────────────

output "ecr_repository_url" {
  value       = module.ecr.repository_url
  description = "ECR repository URL for the FastAPI image."
}

output "ecr_repository_arn" {
  value       = module.ecr.repository_arn
  description = "ECR repository ARN (for IAM policies)."
}

# ── Secrets (T059) ───────────────────────────────────────────────────

output "rds_password_secret_arn" {
  value       = module.secrets.rds_password_secret_arn
  description = "ARN of the RDS master-password secret."
}

output "jwt_secret_arn" {
  value       = module.secrets.jwt_secret_arn
  description = "ARN of the JWT signing-key secret."
}

output "nadlan_recaptcha_key_secret_arn" {
  value       = module.secrets.nadlan_recaptcha_key_secret_arn
  description = "ARN of the nadlan reCAPTCHA-key secret."
}

# ── Database (T056) ──────────────────────────────────────────────────

output "rds_endpoint" {
  value       = module.database.endpoint
  description = "RDS host:port (for DATABASE_URL construction)."
}

output "rds_database_name" {
  value       = module.database.database_name
  description = "RDS initial database name."
}

output "rds_master_username" {
  value       = module.database.master_username
  description = "RDS master username."
}

# ── ALB (T057) ───────────────────────────────────────────────────────

output "alb_dns_name" {
  value       = module.alb.alb_dns_name
  description = "ALB DNS (used as CloudFront /api/* origin in T058)."
}

output "alb_target_group_arn" {
  value       = module.alb.target_group_arn
  description = "Target group ARN — ECS service (T060) attaches here."
}

output "alb_arn" {
  value       = module.alb.alb_arn
  description = "ALB ARN."
}

# ── Storage + CDN (T058) ─────────────────────────────────────────────

output "frontend_bucket_name" {
  value       = module.storage.bucket_name
  description = "S3 bucket hosting the Next.js static build."
}

output "cloudfront_distribution_id" {
  value       = module.storage.cloudfront_distribution_id
  description = "CloudFront distribution ID (for CI invalidations)."
}

output "cloudfront_domain_name" {
  value       = module.storage.cloudfront_domain_name
  description = "Public *.cloudfront.net URL — same origin for frontend + /api/*."
}

# ── ECS (T060) ───────────────────────────────────────────────────────

output "ecs_cluster_name" {
  value       = module.ecs.cluster_name
  description = "ECS cluster name (used by aws ecs execute-command)."
}

output "ecs_service_name" {
  value       = module.ecs.service_name
  description = "ECS service name."
}

output "ecs_task_definition_family" {
  value       = module.ecs.task_definition_family
  description = "Task-definition family (CI registers new revisions here)."
}

output "ecs_task_execution_role_arn" {
  value       = module.ecs.task_execution_role_arn
  description = "Task execution role ARN."
}

output "ecs_task_role_arn" {
  value       = module.ecs.task_role_arn
  description = "Task role ARN (Bedrock + SSM + optional S3)."
}

output "ecs_log_group_name" {
  value       = module.ecs.log_group_name
  description = "CloudWatch log group for the API task."
}

output "database_url_secret_arn" {
  value       = module.ecs.database_url_secret_arn
  description = "ARN of the composed DATABASE_URL secret."
}
