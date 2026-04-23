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
  description = "AWS region — used for Bedrock model ARN construction."
}

# ── Networking inputs ─────────────────────────────────────────────────

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets the tasks run in (from networking module)."
}

variable "ecs_security_group_id" {
  type        = string
  description = "SG for the tasks — accepts container port from ALB only."
}

# ── Image + sizing ────────────────────────────────────────────────────

variable "ecr_repository_url" {
  type        = string
  description = "ECR repository URL (from ecr module). Image ref is ${this}:${image_tag}."
}

variable "ecr_repository_arn" {
  type        = string
  description = "ECR repo ARN — used in the task-execution-role policy."
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Image tag to deploy. CI/CD (T063) overwrites :latest on each push."
}

variable "container_port" {
  type        = number
  default     = 8000
  description = "FastAPI port — must match the ALB target group + ECS SG rule."
}

variable "task_cpu" {
  type        = number
  default     = 256
  description = "Fargate CPU units. 256 = 0.25 vCPU. Adequate for API-only traffic; bump to 512 if we start exec-ing chromium-heavy syncs in-container (see module README)."
}

variable "task_memory_mib" {
  type        = number
  default     = 512
  description = "Fargate memory in MiB. 512 = 0.5 GB."
}

variable "desired_count" {
  type        = number
  default     = 1
  description = "Number of tasks. 1 is enough for staging; ALB handles connection termination during deploys."
}

# ── ALB attachment ────────────────────────────────────────────────────

variable "alb_target_group_arn" {
  type        = string
  description = "Target group ARN from the ALB module."
}

# ── RDS (for DATABASE_URL composition) ────────────────────────────────

variable "rds_endpoint" {
  type        = string
  description = "RDS host:port — used to build DATABASE_URL."
}

variable "rds_database_name" {
  type        = string
  description = "Database name — used to build DATABASE_URL."
}

variable "rds_master_username" {
  type        = string
  description = "DB master user — used to build DATABASE_URL."
}

variable "rds_master_password" {
  type        = string
  sensitive   = true
  description = "DB master password — used to build DATABASE_URL secret value."
}

# ── Secrets Manager inputs (existing secrets) ─────────────────────────

variable "jwt_secret_arn" {
  type        = string
  description = "ARN of the JWT-secret entry in Secrets Manager."
}

variable "nadlan_recaptcha_key_secret_arn" {
  type        = string
  description = "ARN of the nadlan reCAPTCHA-key secret."
}

variable "rds_password_secret_arn" {
  type        = string
  description = "ARN of the RDS master-password secret (ECS Exec shell can read it)."
}

variable "ecs_read_policy_json" {
  type        = string
  description = "IAM policy JSON from the secrets module — allows read on the three secrets."
}

# ── Feature-flag env vars ─────────────────────────────────────────────

variable "feature_flags" {
  type = object({
    query_builder = bool
    backtest      = bool
    pipeline      = bool
    rankings      = bool
  })
  default = {
    query_builder = false
    backtest      = false
    pipeline      = false
    rankings      = false
  }
  description = "Feature flags for the backend — all four off by default for staging."
}

# ── LLM config ────────────────────────────────────────────────────────

variable "bedrock_primary_model_id" {
  type        = string
  default     = "eu.anthropic.claude-haiku-4-5-20251001-v1:0"
  description = "PRIMARY Bedrock inference-profile ID — passed as BEDROCK_MODEL_ID to the container. POC defaults to Haiku 4.5 via the EU cross-region profile (newer Anthropic models require an inference profile, not an on-demand foundation-model ID). To upgrade to Sonnet, set to `eu.anthropic.claude-sonnet-4-6` in tfvars."
}

variable "bedrock_secondary_model_id" {
  type        = string
  default     = "eu.anthropic.claude-haiku-4-5-20251001-v1:0"
  description = "Secondary inference-profile ID — same Haiku 4.5 for the POC. Separate variable so IAM grants invoke on both profiles (harmless when equal; lets you swap PRIMARY → Sonnet without re-applying IAM)."
}

# ── Observability ─────────────────────────────────────────────────────

variable "log_retention_days" {
  type        = number
  default     = 14
  description = "CloudWatch log group retention."
}

# ── ECS Exec ──────────────────────────────────────────────────────────

variable "enable_execute_command" {
  type        = bool
  default     = true
  description = "Allow `aws ecs execute-command` into tasks (admin user management per T050)."
}

# ── Optional: extra S3 bucket for seed restore (T062) ────────────────

variable "seed_bucket_arn" {
  type        = string
  default     = ""
  description = "Optional: S3 bucket ARN that the task role should be allowed to GetObject on. Used by T062 `seed-staging --source s3://...`. Leave empty to skip the extra permission."
}
