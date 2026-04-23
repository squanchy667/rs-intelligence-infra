variable "project_name" {
  type        = string
  description = "Resource name prefix."
}

variable "environment" {
  type        = string
  description = "staging | production"
}

variable "aws_region" {
  type        = string
  description = "AWS region (used for VPC endpoint service names)."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "VPC CIDR block."
}

variable "public_subnet_cidrs" {
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
  description = "Public-subnet CIDRs, one per AZ."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.20.0/24"]
  description = "Private-subnet CIDRs, one per AZ."
}

variable "container_port" {
  type        = number
  default     = 8000
  description = "Port the FastAPI container listens on (for the ECS SG rule)."
}
