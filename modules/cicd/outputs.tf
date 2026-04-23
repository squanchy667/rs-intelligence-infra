output "oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.github.arn
  description = "GitHub Actions OIDC provider ARN (one per AWS account)."
}

output "backend_role_arn" {
  value       = aws_iam_role.backend.arn
  description = "IAM role assumed by the backend deploy workflow. Set this as AWS_DEPLOY_ROLE_ARN in the `staging` environment of the dara-v2 GitHub repo."
}

output "frontend_role_arn" {
  value       = aws_iam_role.frontend.arn
  description = "IAM role assumed by the frontend deploy workflow. Set this as AWS_DEPLOY_ROLE_ARN in the `staging` environment of the dara-v2-ui GitHub repo."
}
