# Shared CloudWatch log group — every environment's SSM deploy command
# writes its aws:runShellScript output here (see modules/gha-deploy-env's
# ssm_box_logs inline policy for the write grant).
resource "aws_cloudwatch_log_group" "deploy" {
  name              = "/rs-intelligence/cicd/deploy"
  retention_in_days = 90

  tags = { Name = "rs-intelligence-cicd-deploy-logs" }
}
