output "cluster_name" {
  value       = aws_ecs_cluster.this.name
  description = "ECS cluster name (used by `aws ecs execute-command`)."
}

output "cluster_arn" {
  value       = aws_ecs_cluster.this.arn
  description = "ECS cluster ARN."
}

output "service_name" {
  value       = aws_ecs_service.api.name
  description = "ECS service name."
}

output "task_definition_arn" {
  value       = aws_ecs_task_definition.api.arn
  description = "ARN of the latest task definition revision."
}

output "task_definition_family" {
  value       = aws_ecs_task_definition.api.family
  description = "Task-definition family (used by GitHub Actions to register new revisions)."
}

output "task_execution_role_arn" {
  value       = aws_iam_role.task_execution.arn
  description = "Task-execution role ARN (CI/CD references for image deploys)."
}

output "task_role_arn" {
  value       = aws_iam_role.task.arn
  description = "Task role ARN — used by the container at runtime (Bedrock, optional S3)."
}

output "log_group_name" {
  value       = aws_cloudwatch_log_group.api.name
  description = "CloudWatch log group."
}

output "database_url_secret_arn" {
  value       = aws_secretsmanager_secret.database_url.arn
  description = "Composed DATABASE_URL secret ARN (injected as env var into the container)."
}
