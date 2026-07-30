variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "project_name" {
  type    = string
  default = "rs-intelligence"
}

variable "github_repo" {
  type        = string
  default     = "squanchy667/dara-v2"
  description = "GitHub \"org/repo\" whose Actions OIDC tokens may assume the dev/test/stg deploy roles."
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Email for the failed-AssumeRole SNS alert. Empty (default) creates the topic + EventBridge wiring but no subscription — set it and re-apply once Ofek picks an address."
}

variable "create_cloudtrail" {
  type        = bool
  default     = true
  description = "Create a dedicated CloudTrail trail (+ its own S3 bucket) logging management events, needed for the failed-AssumeRole EventBridge rule to see anything. Set false if an account-level trail already logs management events somewhere — Ofek confirms which applies at apply time."
}

variable "managed_instance_id_dev" {
  type        = string
  default     = ""
  description = "Fallback pin for the dev box's SSM managed-node ID, if ssm:resourceTag/DeployEnv tag propagation doesn't reach it. See modules/gha-deploy-env/README.md."
}

variable "managed_instance_id_test" {
  type        = string
  default     = ""
  description = "Same fallback for the test box."
}

variable "managed_instance_id_stg" {
  type        = string
  default     = ""
  description = "Same fallback for the stg box. stg isn't green-lit yet (see environments/stg/README.md) — this stays empty until it is."
}

variable "ssm_activation_expiration" {
  type        = string
  default     = null
  description = "RFC3339 expiration timestamp applied to all three SSM activations. Null (default) omits the argument and AWS applies its own default activation window. See README.md for re-creating an activation after it expires."
}
