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
  description = "Lightsail size bundle (dualstack prices, eu-west-1, 2026-09-14): micro_3_0 = 1 GB RAM / 2 vCPU / 40 GB ~ $7/mo (the floor that fits postgres+api+caddy); small_3_0 = 2 GB / 2 vCPU / 60 GB ~ $12/mo. NB: Lightsail cannot resize in place — changing this on an existing instance forces destroy+create (fresh OS, data gone); resize by snapshot → new instance → move the static IP → re-point state instead (DEV.md \"Resize a box\")."
  type        = string
  default     = "micro_3_0"
}

variable "instance_name" {
  description = "Override the instance name (default <project>-<environment>-box). Needed after a snapshot-based resize: Lightsail cannot rename, the old box keeps the original name until it is deleted, and the clone imported into state has to match the name in config."
  type        = string
  default     = null
}
