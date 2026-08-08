variable "name" {
  description = "Base name for database resources"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block for security group rules"
  type        = string
}

variable "private_data_subnet_ids" {
  description = "Private data subnet IDs for RDS and ElastiCache"
  type        = list(string)
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


variable "rds_engine" {
  description = "RDS engine"
  type        = string
  default     = "mysql"
}

variable "rds_engine_version" {
  description = "RDS engine version"
  type        = string
  default     = "8.0"
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "rds_allocated_storage" {
  description = "Allocated storage for RDS"
  type        = number
  default     = 20
}

variable "rds_db_name" {
  description = "Database name"
  type        = string
  default     = "appdb"
}

variable "rds_username" {
  description = "Database admin username"
  type        = string
  default     = "admin"
}

variable "rds_password" {
  description = "Database admin password"
  type        = string
  default     = "ChangeMe123!"
  sensitive   = true
}
