variable "project_name" {
  type        = string
  description = "Resource name prefix."
}

variable "environment" {
  type        = string
  description = "staging | production."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets to place the DB in (from networking module)."
}

variable "security_group_id" {
  type        = string
  description = "RDS SG — allows 5432 from the ECS SG only."
}

variable "master_username" {
  type        = string
  default     = "dara"
  description = "Matches the local Docker superuser."
}

variable "master_password" {
  type        = string
  sensitive   = true
  description = "Supplied from the secrets module (random_password)."
}

variable "database_name" {
  type        = string
  default     = "dara_v2"
  description = "Initial database name — matches local."
}

variable "engine_version" {
  type        = string
  default     = "16.9"
  description = "PostgreSQL minor version. 16.4 was removed from eu-west-1; available 16.x at 2026-04-23: 16.6, 16.8, 16.9, 16.10, 16.11, 16.12, 16.13. Going mid-range; auto_minor_version_upgrade is true so the instance floats forward on AWS's maintenance window."
}

variable "instance_class" {
  type        = string
  default     = "db.t4g.micro"
  description = "Free-tier-eligible burstable; bump to db.t4g.small if memory-bound."
}

variable "allocated_storage_gb" {
  type        = number
  default     = 20
  description = "Initial allocated storage; gp3 can autoscale to max_allocated_storage."
}

variable "max_allocated_storage_gb" {
  type        = number
  default     = 100
  description = "Upper bound for storage autoscaling."
}

variable "backup_retention_days" {
  type        = number
  default     = 7
  description = "Automated backup retention."
}

variable "backup_window" {
  type        = string
  default     = "03:00-04:00"
  description = "UTC window for automated backups (low-traffic hour)."
}

variable "maintenance_window" {
  type        = string
  default     = "Mon:04:00-Mon:05:00"
  description = "UTC maintenance window, staggered after backup window."
}
