############################################################################
# Three secrets in AWS Secrets Manager:
#
#   rs-intelligence/<env>/rds-password         — auto-generated, consumed by
#                                                RDS (T056) and ECS (T060)
#   rs-intelligence/<env>/jwt-secret           — auto-generated, consumed by
#                                                FastAPI auth middleware
#   rs-intelligence/<env>/nadlan-recaptcha-key — placeholder; real value
#                                                written in out-of-band via
#                                                `aws secretsmanager put-secret-value`
#                                                (see module README)
############################################################################

locals {
  name_prefix   = "rs-intelligence/${var.environment}"
  # DB masters can't contain `/`, `@`, `"`, or whitespace — override_special
  # limits us to characters RDS accepts.
  rds_pw_symbols = "!#$%&*+-:<=>?[]_{}~"
}

# ── rds-password ───────────────────────────────────────────────────────

resource "random_password" "rds" {
  length           = var.rds_password_length
  special          = true
  override_special = local.rds_pw_symbols
}

resource "aws_secretsmanager_secret" "rds_password" {
  name                    = "${local.name_prefix}/rds-password"
  description             = "RDS master password for ${local.name_prefix}"
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "rds_password" {
  secret_id     = aws_secretsmanager_secret.rds_password.id
  secret_string = random_password.rds.result
}

# ── jwt-secret ─────────────────────────────────────────────────────────

resource "random_password" "jwt" {
  length  = var.jwt_secret_length
  special = false # HS256 wants a raw opaque string; keep it URL-safe
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "${local.name_prefix}/jwt-secret"
  description             = "HS256 signing key for FastAPI JWTs"
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id     = aws_secretsmanager_secret.jwt_secret.id
  secret_string = random_password.jwt.result
}

# ── nadlan-recaptcha-key (manual value) ───────────────────────────────

resource "aws_secretsmanager_secret" "nadlan_recaptcha" {
  name                    = "${local.name_prefix}/nadlan-recaptcha-key"
  description             = "reCAPTCHA / site-key for the nadlan.gov.il collector. Value rotated in out-of-band."
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "nadlan_recaptcha" {
  secret_id     = aws_secretsmanager_secret.nadlan_recaptcha.id
  secret_string = var.nadlan_recaptcha_key_placeholder

  # Allow the operator to rotate the value via CLI/console without Terraform
  # fighting them on the next apply.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── IAM policy document: ECS task role can read all three ─────────────

data "aws_iam_policy_document" "ecs_read" {
  statement {
    sid     = "ReadStagingSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      aws_secretsmanager_secret.rds_password.arn,
      aws_secretsmanager_secret.jwt_secret.arn,
      aws_secretsmanager_secret.nadlan_recaptcha.arn,
    ]
  }
}
