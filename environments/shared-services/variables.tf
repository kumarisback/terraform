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
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
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
  description = "Create a NAT gateway"
  type        = bool
  default     = true
}

variable "jenkins_instance_type" {
  description = "EC2 instance type for Jenkins"
  type        = string
  default     = "t3.medium"
}

variable "jenkins_allowed_cidrs" {
  description = "CIDR blocks allowed to access Jenkins"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ecr_repositories" {
  description = "List of ECR repository names"
  type        = list(string)
  default     = ["user-service", "order-service", "frontend"]
}

variable "use_local_state" {
  description = "When true, read dev Terraform state from a local file instead of S3"
  type        = bool
  default     = true
}

variable "dev_state_path" {
  description = "Path to the local dev terraform.tfstate when use_local_state is true"
  type        = string
  default     = "../dev/terraform.tfstate"
}

variable "dev_state_bucket" {
  description = "S3 bucket containing dev terraform state (when use_local_state is false)"
  type        = string
  default     = "your-terraform-state-bucket"
}

variable "dev_state_key" {
  description = "S3 key for dev terraform state (when use_local_state is false)"
  type        = string
  default     = "dev/terraform.tfstate"
}

variable "dev_state_region" {
  description = "Region for the dev S3 state"
  type        = string
  default     = "us-east-1"
}

variable "dev_state_dynamodb_table" {
  description = "DynamoDB table for state locking (when use_local_state is false)"
  type        = string
  default     = "your-terraform-lock-table"
}
