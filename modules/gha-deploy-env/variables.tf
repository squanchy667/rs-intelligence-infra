variable "project_name" {
  type        = string
  default     = "rs-intelligence"
  description = "Resource name prefix."
}

variable "env_name" {
  type        = string
  description = "Deploy-ladder environment this instance is for — dev | test | stg. Used in role names, the S3 artifact prefix, and the SSM tag condition."

  validation {
    condition     = contains(["dev", "test", "stg"], var.env_name)
    error_message = "env_name must be one of: dev, test, stg"
  }
}

variable "branch" {
  type        = string
  description = "Git branch this environment deploys from. The trust policy binds the role to exactly this branch — ref-form sub only, no wildcards, no environment-form."
}

variable "github_repo" {
  type        = string
  default     = "squanchy667/dara-v2"
  description = "GitHub \"org/repo\" whose Actions OIDC tokens may assume this role, e.g. \"squanchy667/dara-v2\"."
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the account's GitHub Actions OIDC provider (token.actions.githubusercontent.com). Look this up in the root with a data source — modules/cicd already created the one-per-account provider; do not create a second one here."
}

variable "artifact_bucket_arn" {
  type        = string
  description = "ARN of the shared CI/CD artifact S3 bucket (all envs share one bucket, scoped by prefix)."
}

variable "artifact_bucket_name" {
  type        = string
  description = "Name of the shared CI/CD artifact S3 bucket. Not currently used in a resource ARN here (kept for parity with artifact_bucket_arn and for any future policy needing the bare name), but is a required input so the root always wires both forms together."
}

variable "deploy_document_arn" {
  type        = string
  description = "ARN of the shared aws_ssm_document the deploy workflow runs via ssm:SendCommand."
}

variable "log_group_arn" {
  type        = string
  description = "ARN of the shared CloudWatch log group the box's SSM agent writes command output to."
}

variable "managed_instance_id" {
  type        = string
  default     = ""
  description = "Fallback pin: the mi-* managed-instance ID the deploy role's SsmSendInstance statement is scoped to. Leave \"\" (default) to instead scope by the ssm:resourceTag/DeployEnv=<env_name> condition — the tag every managed node registered via this env's activation carries. Set this only if tag propagation doesn't reach the node in practice; see README.md."
}

variable "activation_expiration" {
  type        = string
  default     = null
  description = "RFC3339 timestamp the SSM hybrid activation expires at. Null (default) omits the argument — AWS applies its own default activation window. See README.md for re-creating an expired activation."
}

variable "account_id" {
  type        = string
  description = "AWS account ID, passed in from the root's aws_caller_identity data source (this module avoids its own data lookups so it stays a pure ARN-builder)."
}

variable "aws_region" {
  type        = string
  default     = "eu-west-1"
  description = "AWS region — used to build the managed-instance ARN pattern."
}
