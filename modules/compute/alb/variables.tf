variable "project_name" {
  type        = string
  description = "Resource name prefix."
}

variable "environment" {
  type        = string
  description = "staging | production."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID (target-group lives in this VPC)."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnets for the ALB."
}

variable "security_group_id" {
  type        = string
  description = "ALB security group (from networking module)."
}

variable "container_port" {
  type        = number
  default     = 8000
  description = "Port the FastAPI container listens on."
}

variable "health_check_path" {
  type        = string
  default     = "/api/health"
  description = "Target-group health-check path (matches FastAPI /api/health from T049)."
}

variable "deregistration_delay_seconds" {
  type        = number
  default     = 30
  description = "Faster drain for staging deploys."
}
