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
