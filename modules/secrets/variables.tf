variable "project_name" {
  type        = string
  description = "Resource name prefix."
}

variable "environment" {
  type        = string
  description = "staging | production — used in secret name path."
}

variable "rds_password_length" {
  type        = number
  default     = 32
  description = "Generated RDS master password length."
}

variable "jwt_secret_length" {
  type        = number
  default     = 64
  description = "Generated JWT HMAC secret length (bytes before base64 trimming)."
}

variable "nadlan_recaptcha_key_placeholder" {
  type        = string
  default     = "CHANGE_ME_VIA_AWS_CLI_OR_CONSOLE"
  description = "Placeholder written on first apply. Real value is rotated in via `aws secretsmanager put-secret-value` (documented in module README)."
}

variable "recovery_window_in_days" {
  type        = number
  default     = 0
  description = "0 = immediate deletion (staging-friendly). Production should use 7–30."
}
