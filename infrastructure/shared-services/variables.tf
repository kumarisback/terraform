variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "microservices"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "shared-services"

  validation {
    condition     = var.environment == "shared-services"
    error_message = "shared-services root module must use environment = \"shared-services\"."
  }
}

# ---------------------------------------------------------
# Shared VPC
# ---------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the shared VPC"
  type        = string
  default     = "10.50.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.50.1.0/24", "10.50.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for private application subnets"
  type        = list(string)
  default     = ["10.50.11.0/24", "10.50.12.0/24"]
}

variable "private_data_subnet_cidrs" {
  description = "CIDR blocks for private data subnets"
  type        = list(string)
  default     = ["10.50.21.0/24", "10.50.22.0/24"]
}

variable "enable_nat_gateway" {
  description = "Whether to create a NAT gateway"
  type        = bool
  default     = true
}

# ---------------------------------------------------------
# Jenkins
# ---------------------------------------------------------

variable "jenkins_instance_type" {
  description = "EC2 instance type for Jenkins"
  type        = string
  default     = "t3.medium"
}

variable "jenkins_allowed_cidrs" {
  description = "CIDR blocks allowed direct SSH/HTTP access to Jenkins. Empty by default — access is via `aws ssm start-session` instead (see README.md)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "jenkins_terraform_deploy_role_arns" {
  description = "IAM role ARNs Jenkins can assume for Terraform deployments."
  type        = list(string)
  default     = []
}

variable "terraform_state_bucket_names" {
  description = "S3 bucket names holding Terraform state for every environment Jenkins provisions (dev/staging/prod + shared-services), used to scope Jenkins' S3 permissions."
  type        = list(string)

  default = [
    "dev-602367507570-us-east-1-an",
    "staging-602367507570-us-east-1-an",
    "prod-602367507570-us-east-1-an"
  ]
}

variable "managed_environments" {
  description = "Environment names Jenkins provisions (used to scope SSM parameter access to /<env>/* paths)."
  type        = list(string)
  default     = ["dev", "staging", "prod"]
}

# ---------------------------------------------------------
# ECR
# ---------------------------------------------------------

variable "ecr_repositories" {
  description = "List of ECR repository names"
  type        = list(string)

  default = [
    "user-service",
    "order-service",
    "frontend"
  ]
}
