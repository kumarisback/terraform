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
  default     = false
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
  default     = null
  sensitive   = true
}

variable "rds_manage_master_user_password" {
  description = "Whether AWS Secrets Manager should manage the RDS master user password."
  type        = bool
  default     = true
}

variable "rds_storage_encrypted" {
  description = "Whether to encrypt RDS storage."
  type        = bool
  default     = true
}

variable "rds_backup_retention_period" {
  description = "Number of days to retain RDS automated backups."
  type        = number
  default     = 7
}

variable "rds_skip_final_snapshot" {
  description = "Whether to skip a final snapshot when deleting RDS."
  type        = bool
  default     = false
}

variable "rds_final_snapshot_identifier" {
  description = "Final snapshot identifier to use when deleting RDS with final snapshots enabled."
  type        = string
  default     = null
}

variable "rds_deletion_protection" {
  description = "Whether deletion protection is enabled for RDS."
  type        = bool
  default     = true
}

variable "rds_apply_immediately" {
  description = "Whether RDS modifications are applied immediately."
  type        = bool
  default     = false
}
