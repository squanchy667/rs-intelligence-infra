variable "project_name" {
  type        = string
  description = "Resource name prefix."
}

variable "environment" {
  type        = string
  description = "staging | production."
}

variable "aws_region" {
  type        = string
  description = "AWS region."
}

# ── ECS target ────────────────────────────────────────────────────────

variable "ecs_cluster_arn" {
  type        = string
  description = "ECS cluster ARN (from compute/ecs module)."
}

variable "ecs_task_definition_arn" {
  type        = string
  description = "Task-definition ARN (:<revision> is fine — EventBridge resolves it)."
}

variable "ecs_task_execution_role_arn" {
  type        = string
  description = "Task-execution role (EventBridge needs iam:PassRole on it)."
}

variable "ecs_task_role_arn" {
  type        = string
  description = "Task role (EventBridge also needs iam:PassRole here)."
}

variable "container_name" {
  type        = string
  default     = "api"
  description = "Container name inside the task def — EventBridge overrides the command on this container."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets the RunTask runs in (awsvpc)."
}

variable "ecs_security_group_id" {
  type        = string
  description = "ECS tasks SG."
}

# ── Schedule toggles ──────────────────────────────────────────────────

variable "enable_daily_sync" {
  type        = bool
  default     = true
  description = "Daily sync --all at 03:00 UTC. Disable if you're running syncs manually (POC flow)."
}

variable "daily_sync_schedule" {
  type        = string
  default     = "cron(0 3 * * ? *)"
  description = "EventBridge cron — 03:00 UTC = 06:00 Israel (IST)."
}

variable "daily_sync_command" {
  type        = list(string)
  default     = ["python", "-m", "dara_v2", "sync", "--all"]
  description = "Command-override for the daily-sync RunTask."
}

variable "enable_weekly_report" {
  type        = bool
  default     = false
  description = "Optional weekly report-generation job. Off by default — bedrock calls cost money and staging reports aren't critical."
}

variable "weekly_report_schedule" {
  type        = string
  default     = "cron(0 5 ? * SUN *)"
  description = "Sunday 05:00 UTC = 08:00 Israel."
}

variable "weekly_report_command" {
  type        = list(string)
  default     = ["python", "-m", "dara_v2", "report", "--all-cities"]
  description = "Command-override for the weekly-report RunTask."
}
