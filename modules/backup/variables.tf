variable "name" {
  description = "Project name, the prefix of everything here"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "selection_tag" {
  description = "Resources (RDS, EBS, EFS) carrying this tag are backed up"
  type = object({
    key   = string
    value = string
  })
  default = {
    key   = "Backup"
    value = "daily"
  }
}

variable "daily_schedule" {
  description = "When the daily backup starts (UTC, AWS cron syntax)"
  type        = string
  default     = "cron(0 3 * * ? *)"
}

variable "daily_retention_days" {
  description = "Days each daily recovery point is kept"
  type        = number
  default     = 35
}

variable "monthly_retention_days" {
  description = "Days each monthly recovery point is kept"
  type        = number
  default     = 365

  validation {
    condition     = var.monthly_retention_days >= 30
    error_message = "A monthly backup kept less than a month is a daily one."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for the vault; null for AWS Backup's managed key"
  type        = string
  default     = null
}

variable "vault_lock" {
  description = "Lock the vault: recovery points can't be deleted before min_retention_days. compliance_after_days null = governance mode (removable with permission); a number = compliance mode, immutable for good after that many days (at least 3)"
  type = object({
    min_retention_days    = number
    max_retention_days    = number
    compliance_after_days = optional(number)
  })
  default = null

  validation {
    condition     = var.vault_lock == null ? true : (var.vault_lock.compliance_after_days == null ? true : var.vault_lock.compliance_after_days >= 3)
    error_message = "Compliance mode needs at least 3 days before it becomes permanent: the time to notice a mistake."
  }
}

variable "copy_to_vault_arn" {
  description = "Another vault (another region, or another account) each daily recovery point is copied to; null for none"
  type        = string
  default     = null
}

variable "notification_email" {
  description = "Address subscribed to failed backups and finished restores (confirm the e-mail AWS sends); null for none"
  type        = string
  default     = null
}
