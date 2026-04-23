variable "project_name" {
  type        = string
  description = "Resource name prefix."
}

variable "environment" {
  type        = string
  description = "staging | production."
}

variable "alert_email" {
  type        = string
  description = "Address the SNS topic emails on alarm transitions."
}

variable "alb_arn_suffix" {
  type        = string
  description = "ALB ARN suffix (e.g. app/<name>/<hash>) — CloudWatch metric dimension for the ALB."
}

variable "alb_target_group_arn_suffix" {
  type        = string
  description = "Target-group ARN suffix — CloudWatch metric dimension."
}

variable "ecs_cluster_name" {
  type        = string
  description = "ECS cluster name — CloudWatch metric dimension."
}

variable "ecs_service_name" {
  type        = string
  description = "ECS service name — CloudWatch metric dimension."
}

variable "unhealthy_evaluation_minutes" {
  type        = number
  default     = 5
  description = "How long UnHealthyHostCount must stay > 0 before paging."
}

variable "running_task_evaluation_minutes" {
  type        = number
  default     = 5
  description = "How long RunningTaskCount must stay < 1 before paging."
}
