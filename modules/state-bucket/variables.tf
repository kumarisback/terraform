variable "bucket" {
  description = "An existing S3 bucket holding Terraform state"
  type        = string
}

variable "noncurrent_days" {
  description = "Days an older state version is kept once newer ones replace it (beyond keep_noncurrent_versions)"
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_days >= 30
    error_message = "Keep older state versions at least 30 days: they are the way back from a bad apply."
  }
}

variable "keep_noncurrent_versions" {
  description = "How many older versions of each state file are kept whatever their age"
  type        = number
  default     = 20
}

variable "kms_key_arn" {
  description = "A customer-managed KMS key to encrypt with; null for S3-managed keys (SSE-S3)"
  type        = string
  default     = null
}
