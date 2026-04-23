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
