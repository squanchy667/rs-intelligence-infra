variable "project_name" {
  type        = string
  description = "Resource name prefix."
}

variable "environment" {
  type        = string
  description = "staging | production — used in role names."
}

variable "github_org" {
  type        = string
  default     = "squanchy667"
  description = "GitHub org/user owning the repos."
}

variable "backend_repo" {
  type        = string
  default     = "dara-v2"
  description = "GitHub repo name for the backend."
}

variable "frontend_repo" {
  type        = string
  default     = "dara-v2-ui"
  description = "GitHub repo name for the frontend."
}

variable "deploy_branch" {
  type        = string
  default     = "main"
  description = "Only workflow runs on this branch are allowed to assume the deploy roles."
}

# ── Backend wiring ────────────────────────────────────────────────────

variable "ecr_repository_arn" {
  type        = string
  description = "ARN of the rs-intelligence-api ECR repo (backend CI pushes here)."
}

variable "ecs_cluster_arn" {
  type        = string
  description = "ECS cluster ARN — backend CI updates the service on it."
}

variable "ecs_service_arn_pattern" {
  type        = string
  description = "Wildcard ARN pattern for the API ECS service, e.g. arn:aws:ecs:region:acct:service/<cluster>/<service>"
}

variable "ecs_task_execution_role_arn" {
  type        = string
  description = "Task-execution role (update-service needs iam:PassRole if it re-registers the task def)."
}

variable "ecs_task_role_arn" {
  type        = string
  description = "Task role — iam:PassRole for the same reason."
}

# ── Frontend wiring ───────────────────────────────────────────────────

variable "frontend_bucket_arn" {
  type        = string
  description = "ARN of the frontend S3 bucket."
}

variable "cloudfront_distribution_arn" {
  type        = string
  description = "ARN of the dual-origin CloudFront distribution."
}
