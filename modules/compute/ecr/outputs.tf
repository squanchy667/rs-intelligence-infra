output "repository_name" {
  value       = aws_ecr_repository.this.name
  description = "ECR repository name."
}

output "repository_url" {
  value       = aws_ecr_repository.this.repository_url
  description = "ECR repository URL — pushed image refs live at <url>:<tag>."
}

output "repository_arn" {
  value       = aws_ecr_repository.this.arn
  description = "ECR repository ARN (used in ECS task-execution-role policy)."
}

output "registry_id" {
  value       = aws_ecr_repository.this.registry_id
  description = "Account ID hosting the registry."
}
