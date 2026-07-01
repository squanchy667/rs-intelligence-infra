############################################################################
# ECS Fargate cluster + backend service for the RS Intelligence API.
#
# Ties together:
#   - ECR (T053)         container image source
#   - Networking (T052)  private subnets, ECS SG
#   - RDS (T056)         DATABASE_URL composition
#   - ALB (T057)         target group attachment
#   - Secrets (T059)     JWT + reCAPTCHA, plus a new DATABASE_URL secret
#                        composed in this module from RDS outputs
############################################################################

data "aws_caller_identity" "current" {}

locals {
  name           = "${var.project_name}-${var.environment}"
  container_name = "api"
  log_group_name = "/ecs/${local.name}"
  account_id     = data.aws_caller_identity.current.account_id

  # Newer Anthropic models in eu-west-1 are only invokable via a cross-region
  # inference profile (e.g. `eu.anthropic.claude-haiku-4-5-...`). The IAM
  # policy must allow InvokeModel on BOTH the inference-profile ARN AND the
  # underlying foundation-model ARNs in every region the profile can route
  # to. The wildcard on region covers eu-west-1 / eu-west-3 / eu-central-1
  # / eu-north-1 without pinning.
  bedrock_invoke_arns = [
    # Inference profile ARNs — what the API actually calls.
    "arn:aws:bedrock:${var.aws_region}:${local.account_id}:inference-profile/${var.bedrock_primary_model_id}",
    "arn:aws:bedrock:${var.aws_region}:${local.account_id}:inference-profile/${var.bedrock_secondary_model_id}",
    # Underlying foundation models (cross-region). Scoped to the Anthropic
    # model families we use; broad region pattern because the profile picks
    # the region at runtime based on capacity.
    "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku-4-5-*",
    "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-*",
    "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-6*",
  ]
}

# ── Composed DATABASE_URL secret ─────────────────────────────────────
#
# RDS password is only known to Terraform (sensitive output from the secrets
# module). We compose the postgresql:// URL here and store it as its own
# secret so the ECS task def can inject DATABASE_URL directly via the
# `secrets` block instead of stitching it together from multiple env vars.

resource "aws_secretsmanager_secret" "database_url" {
  name                    = "rs-intelligence/${var.environment}/database-url"
  description             = "Composed postgresql:// URL for the ${local.name} API"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id = aws_secretsmanager_secret.database_url.id
  secret_string = format(
    "postgresql://%s:%s@%s/%s",
    var.rds_master_username,
    urlencode(var.rds_master_password),
    var.rds_endpoint,
    var.rds_database_name,
  )
}

# ── CloudWatch log group ──────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "api" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days

  tags = { Name = local.log_group_name }
}

# ── ECS cluster ───────────────────────────────────────────────────────

resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "disabled" # not free; enable later if needed
  }

  tags = { Name = local.name }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# ── IAM: task-execution role ─────────────────────────────────────────
# Responsible for: pulling the image from ECR, writing logs, resolving
# secret ARNs into env vars at container start.

data "aws_iam_policy_document" "task_execution_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-task-exec"
  assume_role_policy = data.aws_iam_policy_document.task_execution_assume.json
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  # Managed policy: ECR pull + CloudWatch logs write
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Inline policy: read the specific secret ARNs (JWT, reCAPTCHA, RDS password,
# composed DATABASE_URL). Scoped to exact ARNs, not wildcards.
data "aws_iam_policy_document" "task_execution_secrets" {
  statement {
    sid     = "ReadSecretsForInjection"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      var.jwt_secret_arn,
      var.nadlan_recaptcha_key_secret_arn,
      var.rds_password_secret_arn,
      aws_secretsmanager_secret.database_url.arn,
    ]
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "${local.name}-exec-secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_secrets.json
}

# ── IAM: task role (application perms) ───────────────────────────────
# Invoked at runtime by the container itself: Bedrock, optional S3 for seed
# restore, and SSM for ECS Exec shells.

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.task_execution_assume.json
}

data "aws_iam_policy_document" "task_bedrock" {
  statement {
    sid     = "InvokeClaudeModels"
    effect  = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = local.bedrock_invoke_arns
  }
}

resource "aws_iam_role_policy" "task_bedrock" {
  name   = "${local.name}-task-bedrock"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_bedrock.json
}

# Also let the running container read the same three secrets — needed if an
# admin ECS-Exec's in and runs a CLI command that talks to Secrets Manager
# (e.g. rotating passwords, verifying JWT secret).
resource "aws_iam_role_policy" "task_secrets" {
  name   = "${local.name}-task-secrets"
  role   = aws_iam_role.task.id
  policy = var.ecs_read_policy_json
}

# SSM perms for ECS Exec (interactive shell into running tasks).
data "aws_iam_policy_document" "task_exec_ssm" {
  count = var.enable_execute_command ? 1 : 0

  statement {
    sid    = "ECSExecSSMChannel"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_exec_ssm" {
  count  = var.enable_execute_command ? 1 : 0
  name   = "${local.name}-task-ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec_ssm[0].json
}

# Optional: S3 read for seed restore (T062). Only attached when a bucket ARN
# is provided. Also grants PutObject under snapshots/ for the deep-deep-sleep
# pg_dump uploader (the temp Fargate task launched by scripts/deep-deep-sleep.sh
# reuses this task role rather than provisioning a parallel one-off role).
data "aws_iam_policy_document" "task_seed_s3" {
  count = var.seed_bucket_arn != "" ? 1 : 0

  statement {
    sid       = "ReadSeedBucket"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [var.seed_bucket_arn, "${var.seed_bucket_arn}/*"]
  }

  statement {
    sid       = "WriteSnapshotDumps"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.seed_bucket_arn}/snapshots/*"]
  }
}

resource "aws_iam_role_policy" "task_seed_s3" {
  count  = var.seed_bucket_arn != "" ? 1 : 0
  name   = "${local.name}-task-seed-s3"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_seed_s3[0].json
}

# ── Task definition ──────────────────────────────────────────────────

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  cpu                      = var.task_cpu
  memory                   = var.task_memory_mib
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn      = aws_iam_role.task.arn

  # Runtime platform - ARM64/Graviton.
  # Rationale: operator's build machine is Apple Silicon (arm64), so
  # `docker build` produces an arm64-only image by default. Fargate Graviton
  # runs the same arch natively -> no cross-compile needed, AND ~20% cheaper
  # per vCPU-hour than X86_64 Fargate. Debian slim + chromium + libpq5 all
  # ship arm64 packages so the Dockerfile is unchanged.
  # If you later switch to a GitHub-hosted linux/amd64 runner for CI,
  # either flip this back to X86_64 or build with `docker buildx --platform linux/arm64`.
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = "${var.ecr_repository_url}:${var.image_tag}"
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      # Plain env vars — not sensitive
      environment = [
        { name = "AWS_REGION",           value = var.aws_region },
        { name = "LLM_PROVIDER",         value = "bedrock" },
        { name = "BEDROCK_MODEL_ID",     value = var.bedrock_primary_model_id },
        { name = "FF_QUERY_BUILDER",     value = tostring(var.feature_flags.query_builder) },
        { name = "FF_BACKTEST",          value = tostring(var.feature_flags.backtest) },
        { name = "FF_PIPELINE",          value = tostring(var.feature_flags.pipeline) },
        { name = "FF_RANKINGS",          value = tostring(var.feature_flags.rankings) },
        # Staging trusts CloudFront as same-origin, so "*" is fine here
        { name = "CORS_ALLOW_ORIGINS",   value = "*" },
        { name = "CHROME_HEADLESS",      value = "true" },
      ]

      # Secrets — resolved to env vars at container start by the execution role
      secrets = [
        { name = "DATABASE_URL",         valueFrom = aws_secretsmanager_secret.database_url.arn },
        { name = "JWT_SECRET",           valueFrom = var.jwt_secret_arn },
        { name = "NADLAN_RECAPTCHA_KEY", valueFrom = var.nadlan_recaptcha_key_secret_arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = local.container_name
        }
      }

      # Container-level health check — ECS marks the task unhealthy if
      # /api/health fails three times in a row. Complements the ALB check.
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/api/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
    }
  ])

  tags = { Name = "${local.name}-api-taskdef" }
}

# ── ECS service ──────────────────────────────────────────────────────

resource "aws_ecs_service" "api" {
  name            = "${local.name}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  enable_execute_command = var.enable_execute_command

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.alb_target_group_arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  # Grace period before the ALB health check can fail the service. Needs to
  # cover `pip`-cached cold start + app init (~20-30 s on a clean image).
  health_check_grace_period_seconds = 60

  # Staging deploys: one task up, one down — acceptable for internal testing.
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 0

  propagate_tags = "SERVICE"

  lifecycle {
    # CI/CD (T063) rolls the task def to a new image tag. Ignore that so
    # `terraform apply` doesn't immediately roll it back.
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_cloudwatch_log_group.api]

  tags = { Name = "${local.name}-api-service" }
}
