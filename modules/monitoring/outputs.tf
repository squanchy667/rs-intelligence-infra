output "alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "SNS topic ARN (future alarms can plug into it)."
}

output "alb_unhealthy_alarm_name" {
  value       = aws_cloudwatch_metric_alarm.alb_unhealthy.alarm_name
  description = "Name of the ALB unhealthy-host alarm."
}

output "ecs_no_task_alarm_name" {
  value       = aws_cloudwatch_metric_alarm.ecs_no_running_task.alarm_name
  description = "Name of the ECS no-running-task alarm."
}
