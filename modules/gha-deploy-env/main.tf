############################################################################
# One deploy environment on the GitHub Actions CI/CD ladder.
#
# Two roles:
#   - gha_deploy  assumed by GitHub Actions via OIDC (AssumeRoleWithWebIdentity),
#                 scoped to exactly one branch (ref-form sub only). Can only
#                 write to its own S3 artifact prefix, send the shared deploy
#                 document, and poll SSM command status.
#   - ssm_box     assumed by the SSM agent running on the Lightsail box
#                 (hybrid activation — Lightsail has no instance profiles, so
#                 the box registers as an mi-* managed node instead of an
#                 ec2 instance). Grants AmazonSSMManagedInstanceCore plus
#                 CloudWatch Logs write for command output.
#
# Plus one aws_ssm_activation that mints the code/id pair used to register
# this environment's box as a managed node under ssm_box.
############################################################################

locals {
  deploy_name = "${var.project_name}-gha-deploy-${var.env_name}"
  box_name    = "${var.project_name}-ssm-box-${var.env_name}"

  # Scope SsmSendInstance either to a single pinned managed-instance ID, or
  # (default) to the wildcard managed-instance ARN pattern gated by the
  # ssm:resourceTag/DeployEnv condition below. Exactly one of these two
  # forms is used per env — see variables.tf managed_instance_id.
  ssm_instance_resource = var.managed_instance_id != "" ? "arn:aws:ssm:${var.aws_region}:${var.account_id}:managed-instance/${var.managed_instance_id}" : "arn:aws:ssm:${var.aws_region}:${var.account_id}:managed-instance/*"
}

# ── GitHub Actions deploy role (OIDC) ─────────────────────────────────

data "aws_iam_policy_document" "gha_deploy_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # REF FORM ONLY, exactly one value. Unlike modules/cicd (which accepts
    # both ref-form and environment-form subs for the ECS staging deploy),
    # this ladder binds every role to a single named branch — no wildcards,
    # no environment-form, so a differently-named branch or a forked PR
    # can never assume it.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/${var.branch}"]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  name                 = local.deploy_name
  assume_role_policy   = data.aws_iam_policy_document.gha_deploy_assume.json
  max_session_duration = 3600

  tags = { Name = local.deploy_name }
}

data "aws_iam_policy_document" "gha_deploy" {
  # Env-scoped artifact read/write only — this role can never touch another
  # environment's prefix in the shared bucket.
  statement {
    sid       = "S3ArtifactObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${var.artifact_bucket_arn}/${var.env_name}/*"]
  }

  # ListBucket is bucket-level (no object suffix) — gate it with the
  # s3:prefix condition so listing is also confined to this env's prefix.
  statement {
    sid       = "S3ArtifactList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.artifact_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.env_name}/*"]
    }
  }

  statement {
    sid       = "SsmSendDocument"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = [var.deploy_document_arn]
  }

  # SendCommand needs both the document ARN (above) AND the target
  # instance ARN allowed — AWS evaluates them as separate resources on the
  # same action, not the same statement.
  statement {
    sid       = "SsmSendInstance"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = [local.ssm_instance_resource]

    dynamic "condition" {
      for_each = var.managed_instance_id == "" ? [1] : []
      content {
        test     = "StringEquals"
        variable = "ssm:resourceTag/DeployEnv"
        values   = [var.env_name]
      }
    }
  }

  # GetCommandInvocation has no resource-level ARN support — "*" is the
  # only valid resource for this action.
  statement {
    sid       = "SsmPoll"
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gha_deploy" {
  name   = local.deploy_name
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.gha_deploy.json
}

# ── SSM box role (hybrid activation) ──────────────────────────────────

data "aws_iam_policy_document" "ssm_box_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm_box" {
  name               = local.box_name
  assume_role_policy = data.aws_iam_policy_document.ssm_box_assume.json

  tags = { Name = local.box_name }
}

resource "aws_iam_role_policy_attachment" "ssm_box_core" {
  role       = aws_iam_role.ssm_box.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ssm_box_logs" {
  statement {
    sid       = "SsmBoxLogWrite"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${var.log_group_arn}:*"]
  }

  # No resource-level ARN support for these two — needed so the SSM agent
  # can resolve the log group/stream it just wrote via CreateLogStream.
  statement {
    sid       = "SsmBoxLogDescribe"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups", "logs:DescribeLogStreams"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ssm_box_logs" {
  name   = "${local.box_name}-logs"
  role   = aws_iam_role.ssm_box.id
  policy = data.aws_iam_policy_document.ssm_box_logs.json
}

# ── SSM hybrid activation ──────────────────────────────────────────────
#
# Lightsail instances have no IAM instance-profile mechanism, so they can't
# register as normal EC2 managed nodes. A hybrid activation mints a
# code/id pair the SSM agent on the box uses to self-register as an mi-*
# managed node instead (see README.md for the box-side registration
# command).
resource "aws_ssm_activation" "this" {
  name               = "${var.project_name}-cicd-${var.env_name}"
  iam_role           = aws_iam_role.ssm_box.id
  registration_limit = 1
  expiration_date    = var.activation_expiration

  # Tags on the activation propagate to every managed node registered
  # through it — this is the tag-propagation mechanism the SsmSendInstance
  # condition (ssm:resourceTag/DeployEnv) above relies on when
  # managed_instance_id is left unset. Docs:
  # https://docs.aws.amazon.com/systems-manager/latest/userguide/hybrid-multicloud-managed-nodes-tags.html
  tags = {
    DeployEnv = var.env_name
  }

  depends_on = [aws_iam_role_policy_attachment.ssm_box_core]
}
