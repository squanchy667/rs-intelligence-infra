variable "project_name" {
  type        = string
  description = "Resource name prefix."
}

variable "environment" {
  type        = string
  description = "staging | production."
}

variable "alb_dns_name" {
  type        = string
  description = "ALB DNS name — used as the CloudFront /api/* origin host."
}

variable "bucket_name_suffix" {
  type        = string
  default     = "frontend"
  description = "Appended to the project/env prefix to form the S3 bucket name."
}

variable "price_class" {
  type        = string
  default     = "PriceClass_100"
  description = "CloudFront price class. PriceClass_100 = US/CA/Europe (cheapest)."
}
