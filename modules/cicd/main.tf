############################################################################
# GitHub Actions → AWS deployment IAM (OIDC, no long-lived keys).
#
# Creates one shared OIDC provider and two least-privilege deploy roles:
#   - <project>-<env>-github-backend   pushes to ECR, rolls the ECS service
#   - <project>-<env>-github-frontend  syncs the S3 bucket, invalidates CF
#
# Each role trusts only:
#   repo:<org>/<repo>:ref:refs/heads/<deploy_branch>
# so a fork or a PR branch can't assume it.
############################################################################

locals {
  name = "${var.project_name}-${var.environment}"
}

# GitHub's OIDC provider. One per AWS account (if re-applying against an
# account that already has it, import rather than re-create).
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # The GitHub Actions OIDC issuer presents the "6938fd4d..." thumbprint.
  # AWS stopped requiring exact-match in 2023 but the provider still wants
  # at least one value — using the long-documented thumbprint is stable.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { Name = "${local.name}-github-oidc" }
}

# ── Backend: ECR push + ECS roll ─────────────────────────────────────

data "aws_iam_policy_document" "backend_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Accept both sub-claim formats — the ref form for plain pushes and the
    # environment form that GH emits when the workflow job has
    # `environment: <name>`. Our deploy workflows use `environment: staging`
    # for secret scoping, so the environment form is what we actually see.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.backend_repo}:ref:refs/heads/${var.deploy_branch}",
        "repo:${var.github_org}/${var.backend_repo}:environment:${var.deploy_branch}",
      ]
    }
  }
}

resource "aws_iam_role" "backend" {
  name               = "${local.name}-github-backend"
  assume_role_policy = data.aws_iam_policy_document.backend_assume.json

  tags = { Name = "${local.name}-github-backend" }
}

data "aws_iam_policy_document" "backend" {
  # ECR authorization token is account-wide (no ARN granularity).
  statement {
    sid       = "ECRAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push + pull on the specific repo only.
  statement {
    sid       = "ECRPushPull"
    effect    = "Allow"
    actions   = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [var.ecr_repository_arn]
  }

  # Roll the ECS service.
  statement {
    sid    = "ECSDeploy"
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition",
    ]
    # UpdateService / DescribeServices scope to the service ARN pattern;
    # RegisterTaskDefinition has no resource-level ARN (service-wide).
    resources = ["*"]

    condition {
      test     = "ArnEqualsIfExists"
      variable = "ecs:cluster"
      values   = [var.ecs_cluster_arn]
    }
  }

  # RegisterTaskDefinition creates a new revision that references both
  # roles — PassRole is mandatory.
  statement {
    sid       = "PassECSRolesToTaskDef"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [var.ecs_task_execution_role_arn, var.ecs_task_role_arn]
  }
}

resource "aws_iam_role_policy" "backend" {
  name   = "${local.name}-github-backend"
  role   = aws_iam_role.backend.id
  policy = data.aws_iam_policy_document.backend.json
}

# ── Frontend: S3 sync + CloudFront invalidation ──────────────────────

data "aws_iam_policy_document" "frontend_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Same as the backend — accept both ref-form and environment-form sub
    # claims so `environment: staging` in the workflow works.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.frontend_repo}:ref:refs/heads/${var.deploy_branch}",
        "repo:${var.github_org}/${var.frontend_repo}:environment:${var.deploy_branch}",
      ]
    }
  }
}

resource "aws_iam_role" "frontend" {
  name               = "${local.name}-github-frontend"
  assume_role_policy = data.aws_iam_policy_document.frontend_assume.json

  tags = { Name = "${local.name}-github-frontend" }
}

data "aws_iam_policy_document" "frontend" {
  # Bucket-level list (for sync --delete).
  statement {
    sid       = "S3ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketTagging"]
    resources = [var.frontend_bucket_arn]
  }

  # Object-level write on contents of the frontend bucket only.
  statement {
    sid    = "S3ObjectWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${var.frontend_bucket_arn}/*"]
  }

  # CloudFront invalidation — resource-level arn supported since 2021.
  statement {
    sid       = "CloudFrontInvalidate"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetDistribution", "cloudfront:GetInvalidation"]
    resources = [var.cloudfront_distribution_arn]
  }
}

resource "aws_iam_role_policy" "frontend" {
  name   = "${local.name}-github-frontend"
  role   = aws_iam_role.frontend.id
  policy = data.aws_iam_policy_document.frontend.json
}
