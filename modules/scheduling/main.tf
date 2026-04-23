############################################################################
# EventBridge → ECS RunTask
#
#   daily-sync     03:00 UTC    python -m dara_v2 sync --all
#   weekly-report  Sun 05:00    python -m dara_v2 report --all-cities  (opt-in)
#
# Both reuse the API task definition from module.ecs and override the
# container command. Logs land in the same /ecs/<name> log group the API
# service already uses, so the operator reads every invocation in one place.
############################################################################

locals {
  name = "${var.project_name}-${var.environment}"
}

# ── IAM role EventBridge assumes to run ECS tasks ─────────────────────

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid     = "RunTaskOnECSCluster"
    effect  = "Allow"
    actions = ["ecs:RunTask"]
    # EventBridge passes the task definition ARN. Drop the :<revision> suffix
    # so new revisions created by CI/CD are covered automatically.
    resources = [
      replace(var.ecs_task_definition_arn, "/:\\d+$/", ":*"),
      var.ecs_task_definition_arn,
    ]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.ecs_cluster_arn]
    }
  }

  statement {
    sid       = "PassExecutionAndTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [var.ecs_task_execution_role_arn, var.ecs_task_role_arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${local.name}-scheduler"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

# ── Daily sync ────────────────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "daily_sync" {
  count = var.enable_daily_sync ? 1 : 0

  name                = "${local.name}-daily-sync"
  description         = "Daily sync --all (all collectors, all tracked cities)"
  schedule_expression = var.daily_sync_schedule
  state               = "ENABLED"
}

resource "aws_cloudwatch_event_target" "daily_sync" {
  count = var.enable_daily_sync ? 1 : 0

  rule     = aws_cloudwatch_event_rule.daily_sync[0].name
  arn      = var.ecs_cluster_arn
  role_arn = aws_iam_role.scheduler.arn

  ecs_target {
    task_definition_arn = var.ecs_task_definition_arn
    task_count          = 1
    launch_type         = "FARGATE"

    network_configuration {
      subnets          = var.private_subnet_ids
      security_groups  = [var.ecs_security_group_id]
      assign_public_ip = false
    }
  }

  input = jsonencode({
    containerOverrides = [
      {
        name    = var.container_name
        command = var.daily_sync_command
      },
    ]
  })
}

# ── Weekly report (opt-in) ───────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "weekly_report" {
  count = var.enable_weekly_report ? 1 : 0

  name                = "${local.name}-weekly-report"
  description         = "Weekly report generation across all tracked cities"
  schedule_expression = var.weekly_report_schedule
  state               = "ENABLED"
}

resource "aws_cloudwatch_event_target" "weekly_report" {
  count = var.enable_weekly_report ? 1 : 0

  rule     = aws_cloudwatch_event_rule.weekly_report[0].name
  arn      = var.ecs_cluster_arn
  role_arn = aws_iam_role.scheduler.arn

  ecs_target {
    task_definition_arn = var.ecs_task_definition_arn
    task_count          = 1
    launch_type         = "FARGATE"

    network_configuration {
      subnets          = var.private_subnet_ids
      security_groups  = [var.ecs_security_group_id]
      assign_public_ip = false
    }
  }

  input = jsonencode({
    containerOverrides = [
      {
        name    = var.container_name
        command = var.weekly_report_command
      },
    ]
  })
}
