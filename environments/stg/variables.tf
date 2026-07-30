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
  description = "Lightsail size. micro_3_0 = 1 GB ~ $5/mo."
  type        = string
  default     = "micro_3_0"
}
