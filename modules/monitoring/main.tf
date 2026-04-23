############################################################################
# SNS topic + email subscription + CloudWatch alarms for the backend service.
#
# Two alarms, both resolve to the same SNS topic → email:
#   - ALB UnHealthyHostCount > 0 for N minutes  (tasks running but failing health)
#   - ECS RunningTaskCount   < 1 for N minutes  (no tasks at all)
#
# SNS email subscriptions require confirmation (AWS sends a link to alert_email
# the first time). Until confirmed the subscription is `PendingConfirmation`
# and nothing is delivered.
############################################################################

locals {
  name = "${var.project_name}-${var.environment}"
}

# ── SNS topic + email subscription ───────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"

  tags = { Name = "${local.name}-alerts" }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── ALB unhealthy target alarm ───────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy" {
  alarm_name          = "${local.name}-alb-unhealthy-host"
  alarm_description   = "ALB target group reporting at least one unhealthy host for ${var.unhealthy_evaluation_minutes}+ minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.unhealthy_evaluation_minutes
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60 # 1-minute datapoints
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.alb_target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Name = "${local.name}-alb-unhealthy-host" }
}

# ── ECS no-running-task alarm ────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "ecs_no_running_task" {
  alarm_name          = "${local.name}-ecs-no-running-task"
  alarm_description   = "ECS service has fewer than 1 running task for ${var.running_task_evaluation_minutes}+ minutes (desired count not met)."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.running_task_evaluation_minutes
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  # During a deploy there's a few seconds between the old task stopping and
  # the new one becoming healthy. The metric can briefly be "missing" — treat
  # that as healthy so we don't page on every rollout.
  treat_missing_data = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Name = "${local.name}-ecs-no-running-task" }
}
