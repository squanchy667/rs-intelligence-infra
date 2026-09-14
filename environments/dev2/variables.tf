variable "project_name" {
  type    = string
  default = "rs-intelligence"
}

variable "environment" {
  type    = string
  default = "dev2"
}

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "bundle_id" {
  description = "Lightsail size. micro_3_0 = 1 GB ~ $7/mo (dualstack); small_3_0 = 2 GB ~ $12/mo. Not resizable in place — see modules/dev-box/variables.tf."
  type        = string
  default     = "micro_3_0"
}

variable "instance_name" {
  description = "Instance name override (see modules/dev-box). null = <project>-<environment>-box."
  type        = string
  default     = null
}
