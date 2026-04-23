variable "project_name" {
  description = "Short project identifier used as a prefix for AWS resource names."
  type        = string
  default     = "rs-intelligence"
}

variable "environment" {
  description = "Deployment environment (staging | production)."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be one of: staging, production"
  }
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-west-1"
}

variable "alert_email" {
  description = "Email for CloudWatch alarm notifications (T066)."
  type        = string
  default     = "ofekaviv9@gmail.com"
}

variable "scheduling_enable_daily_sync" {
  description = "Enable the EventBridge daily-sync cron (T065)."
  type        = bool
  default     = true
}

variable "scheduling_enable_weekly_report" {
  description = "Enable the opt-in EventBridge weekly-report cron (T065)."
  type        = bool
  default     = false
}
