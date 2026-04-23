variable "project_name" {
  type        = string
  description = "Resource name prefix."
}

variable "environment" {
  type        = string
  description = "staging | production — used for tags only; the repo name itself is shared across environments."
}

variable "repository_name" {
  type        = string
  default     = "rs-intelligence-api"
  description = "ECR repository name. Single repo for both FastAPI staging and prod images."
}

variable "image_tag_mutability" {
  type        = string
  default     = "MUTABLE"
  description = "MUTABLE allows reusing the `latest` tag; IMMUTABLE for production safety."
}

variable "scan_on_push" {
  type        = bool
  default     = true
  description = "Run basic image scanning on every push."
}

variable "keep_last_tagged_images" {
  type        = number
  default     = 5
  description = "Lifecycle rule: retain at most this many tagged images."
}

variable "untagged_image_ttl_days" {
  type        = number
  default     = 1
  description = "Lifecycle rule: expire untagged images after this many days."
}
