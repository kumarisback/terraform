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
  description = "CIDR blocks allowed to access Jenkins. For learning this may be 0.0.0.0/0, but production should use your IP or VPN CIDR."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "terraform_deploy_role_arns" {
  description = "IAM role ARNs Jenkins is allowed to assume for Terraform deployments. Prefer one scoped role per environment."
  type        = list(string)
  default     = []
}
