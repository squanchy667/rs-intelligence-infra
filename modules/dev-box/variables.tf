variable "project_name" {
  description = "Resource name prefix."
  type        = string
  default     = "rs-intelligence"
}

variable "environment" {
  description = "Environment tag — 'dev' for this lean box."
  type        = string
  default     = "dev"
}

variable "availability_zone" {
  description = "Lightsail AZ (must be in the provider region)."
  type        = string
  default     = "eu-west-1a"
}

variable "blueprint_id" {
  description = "Lightsail OS blueprint."
  type        = string
  default     = "ubuntu_24_04"
}

variable "bundle_id" {
  description = "Lightsail size bundle. micro_3_0 = 1 GB RAM / 2 vCPU ~ $5/mo (the floor that fits postgres+api+caddy)."
  type        = string
  default     = "micro_3_0"
}
