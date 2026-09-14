variable "project_name" {
  type    = string
  default = "rs-intelligence"
}

variable "environment" {
  type    = string
  default = "stg"
}

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "bundle_id" {
  description = "Lightsail size (dualstack, eu-west-1): micro_3_0 = 1 GB ~ $7/mo, small_3_0 = 2 GB ~ $12/mo. stg runs small_3_0 (terraform.tfvars). Resize = snapshot → clone → import, never in place (DEV.md \"Resize a box\")."
  type        = string
  default     = "micro_3_0"
}

variable "instance_name" {
  description = "Override the instance name (default <project>-<environment>-box). Set after a snapshot-based resize — the clone imported into state must match the name in config; the old box keeps the original name until deleted. Same shape as environments/dev and dev2."
  type        = string
  default     = null
}
