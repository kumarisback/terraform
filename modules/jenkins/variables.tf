variable "name" {
  description = "Base name for the infrastructure"
  type        = string
}

variable "environment" {
  description = "Environment name such as dev, staging, or prod"
  type        = string
}

variable "vpc_id" {
  description = "The VPC ID where Jenkins should be created"
  type        = string
}

variable "subnet_id" {
  description = "The subnet ID for the Jenkins instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for Jenkins"
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "Optional custom AMI ID"
  type        = string
  default     = ""
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed direct SSH/HTTP access to Jenkins. Empty by default — access is via `aws ssm start-session` instead (see README.md), which needs no open inbound port. Only set this if you specifically want a direct network path (e.g. from a VPN CIDR)."
  type        = list(string)
  default     = []
}

variable "terraform_deploy_role_arns" {
  description = "IAM role ARNs Jenkins is allowed to assume for Terraform deployments. Prefer one scoped role per environment."
  type        = list(string)
  default     = []
}

variable "state_bucket_names" {
  description = "S3 bucket names holding Terraform state that Jenkins needs read/write access to. Used to scope S3 permissions instead of granting AmazonS3FullAccess."
  type        = list(string)
  default     = []
}

variable "managed_environments" {
  description = "Environment names Jenkins provisions (used to scope SSM parameter access to /<env>/* paths)."
  type        = list(string)
  default     = ["dev", "staging", "prod"]
}
