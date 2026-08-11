variable "secret_name" {
  description = "Name of the AWS Secrets Manager secret containing environment values"
  type        = string
}

variable "secret_arn" {
  description = "ARN of the AWS Secrets Manager secret (optional)"
  type        = string
  default     = ""
}

variable "manage_secret" {
  description = "When true, module creates and manages the secret in AWS Secrets Manager using provided secret_values."
  type        = bool
  default     = false
}

variable "secret_values" {
  description = "Map of key -> value pairs to write into the secret when manage_secret is true"
  type        = map(string)
  default     = {}
  sensitive   = true
}
