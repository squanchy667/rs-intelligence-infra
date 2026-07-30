output "deploy_role_arn" {
  value       = aws_iam_role.gha_deploy.arn
  description = "GitHub Actions deploy role ARN. Set as the AWS role secret/var for this branch's environment in the dara-v2 repo."
}

output "deploy_role_name" {
  value       = aws_iam_role.gha_deploy.name
  description = "GitHub Actions deploy role name."
}

output "box_role_arn" {
  value       = aws_iam_role.ssm_box.arn
  description = "SSM hybrid-activation role ARN assumed by the box's SSM agent."
}

output "activation_id" {
  value       = aws_ssm_activation.this.id
  description = "SSM activation ID — pair with activation_code to register the box (see README.md)."
}

output "activation_code" {
  value       = aws_ssm_activation.this.activation_code
  description = "SSM activation code — sensitive, single-use per registration_limit = 1."
  sensitive   = true
}
