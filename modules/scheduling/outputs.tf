output "scheduler_role_arn" {
  value       = aws_iam_role.scheduler.arn
  description = "IAM role EventBridge uses to invoke ECS RunTask."
}

output "daily_sync_rule_name" {
  value       = try(aws_cloudwatch_event_rule.daily_sync[0].name, null)
  description = "Daily-sync rule name (null if disabled)."
}

output "weekly_report_rule_name" {
  value       = try(aws_cloudwatch_event_rule.weekly_report[0].name, null)
  description = "Weekly-report rule name (null if disabled)."
}
