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
  default     = "staging"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for private application subnets"
  type        = list(string)
  default     = ["10.20.11.0/24", "10.20.12.0/24"]
}

variable "private_data_subnet_cidrs" {
  description = "CIDR blocks for private data subnets"
  type        = list(string)
  default     = ["10.20.21.0/24", "10.20.22.0/24"]
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway"
  type        = bool
  default     = true
}

variable "cluster_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.36"
}

variable "node_desired_capacity" {
  description = "Desired number of EKS worker nodes"
  type        = number
  default     = 2
}

variable "node_min_capacity" {
  description = "Minimum number of EKS worker nodes"
  type        = number
  default     = 1
}

variable "node_max_capacity" {
  description = "Maximum number of EKS worker nodes"
  type        = number
  default     = 5
}

variable "node_instance_type" {
  description = "EKS worker instance type"
  type        = string
  default     = "t3.medium"
}

variable "enable_rds" {
  description = "Enable RDS database"
  type        = bool
  default     = false
}

variable "enable_elasticache" {
  description = "Enable ElastiCache Redis"
  type        = bool
  default     = true
}

variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "secret_name" {
  description = "AWS Secrets Manager secret name for environment values"
  type        = string
  default     = "microservices/staging/app-config"
}
