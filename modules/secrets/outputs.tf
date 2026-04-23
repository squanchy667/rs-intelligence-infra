output "rds_password_secret_arn" {
  value       = aws_secretsmanager_secret.rds_password.arn
  description = "ARN of the RDS master-password secret (consumed by RDS + ECS modules)."
}

output "rds_password" {
  value       = random_password.rds.result
  sensitive   = true
  description = "Plaintext RDS password — wired directly into aws_db_instance in the database module to avoid a chicken/egg on version reads."
}

output "jwt_secret_arn" {
  value       = aws_secretsmanager_secret.jwt_secret.arn
  description = "ARN of the JWT signing-key secret (consumed by ECS task def)."
}

output "nadlan_recaptcha_key_secret_arn" {
  value       = aws_secretsmanager_secret.nadlan_recaptcha.arn
  description = "ARN of the nadlan reCAPTCHA secret (consumed by ECS task def)."
}

output "ecs_read_policy_json" {
  value       = data.aws_iam_policy_document.ecs_read.json
  description = "IAM policy JSON to attach to the ECS task role (allows read on the three secrets only)."
}
