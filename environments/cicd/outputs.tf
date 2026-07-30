# ── Shared resources ─────────────────────────────────────────────────

output "artifact_bucket_name" {
  value       = aws_s3_bucket.artifacts.id
  description = "Shared CI/CD artifact bucket name."
}

output "artifact_bucket_arn" {
  value       = aws_s3_bucket.artifacts.arn
  description = "Shared CI/CD artifact bucket ARN."
}

output "deploy_document_name" {
  value       = aws_ssm_document.gha_deploy.name
  description = "Shared SSM deploy document name — target of ssm:SendCommand from every environment."
}

output "log_group_name" {
  value       = aws_cloudwatch_log_group.deploy.name
  description = "Shared CloudWatch log group for SSM command output."
}

output "alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "SNS topic the failed-AssumeRole alarm publishes to."
}

# ── dev ──────────────────────────────────────────────────────────────

output "dev_deploy_role_arn" {
  value       = module.dev.deploy_role_arn
  description = "Dev deploy role ARN — set as the GitHub Actions AWS role for the dev environment/branch."
}

output "dev_box_role_arn" {
  value       = module.dev.box_role_arn
  description = "Dev box's SSM hybrid-activation role ARN."
}

output "dev_activation_id" {
  value       = module.dev.activation_id
  description = "Dev box SSM activation ID."
}

output "dev_activation_code" {
  value       = module.dev.activation_code
  description = "Dev box SSM activation code."
  sensitive   = true
}

# ── test ─────────────────────────────────────────────────────────────

output "test_deploy_role_arn" {
  value       = module.test.deploy_role_arn
  description = "Test deploy role ARN — set as the GitHub Actions AWS role for the test environment/branch."
}

output "test_box_role_arn" {
  value       = module.test.box_role_arn
  description = "Test box's SSM hybrid-activation role ARN."
}

output "test_activation_id" {
  value       = module.test.activation_id
  description = "Test box SSM activation ID."
}

output "test_activation_code" {
  value       = module.test.activation_code
  description = "Test box SSM activation code."
  sensitive   = true
}

# ── stg ──────────────────────────────────────────────────────────────

output "stg_deploy_role_arn" {
  value       = module.stg.deploy_role_arn
  description = "Stg deploy role ARN — set as the GitHub Actions AWS role for the stg environment/branch, once stg is green-lit."
}

output "stg_box_role_arn" {
  value       = module.stg.box_role_arn
  description = "Stg box's SSM hybrid-activation role ARN."
}

output "stg_activation_id" {
  value       = module.stg.activation_id
  description = "Stg box SSM activation ID."
}

output "stg_activation_code" {
  value       = module.stg.activation_code
  description = "Stg box SSM activation code."
  sensitive   = true
}
