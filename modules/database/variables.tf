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

variable "client_security_group_ids" {
  description = "Security groups whose members may connect (the EKS cluster security group, which the nodes and their pods carry)"
  type        = list(string)

  validation {
    condition     = length(var.client_security_group_ids) > 0
    error_message = "Name at least one client security group: with none, nothing could connect."
  }
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
  description = "RDS engine: PostgreSQL only (its parameter group and port, roadmap step 23)"
  type        = string
  default     = "postgres"

  validation {
    condition     = var.rds_engine == "postgres"
    error_message = "The module sets up PostgreSQL only (parameter group, port, log exports)."
  }
}

variable "rds_engine_version" {
  description = "PostgreSQL major version; RDS picks the newest minor and upgrades minors on its own"
  type        = string
  default     = "17"
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
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

variable "rds_multi_az" {
  description = "A synchronous standby in another availability zone, failed over to automatically. Doubles the instance's cost."
  type        = bool
  default     = true
}

variable "rds_max_allocated_storage" {
  description = "Storage autoscaling's ceiling in GiB (allocated_storage is the start)"
  type        = number
  default     = 100
}

variable "rds_ca_cert_identifier" {
  description = "CA of the server certificate; clients verify against AWS's bundle"
  type        = string
  default     = "rds-ca-rsa2048-g1"
}

variable "rds_performance_insights_enabled" {
  description = "Database Insights (Performance Insights), standard mode: 7 days kept, free"
  type        = bool
  default     = true
}

variable "rds_monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds (0 turns it off)"
  type        = number
  default     = 60
}

variable "rds_read_replica" {
  description = "Create a read replica too (asynchronous, readable; another instance's cost)"
  type        = bool
  default     = false
}

variable "rds_connections_alarm_threshold" {
  description = "Alarm when connections pass this (db.t4g.micro allows about 80: max_connections is memory / 9531392)"
  type        = number
  default     = 60
}

variable "alarm_actions" {
  description = "Where the RDS alarms notify (SNS topic ARNs); none: they only show in CloudWatch"
  type        = list(string)
  default     = []
}

variable "rds_proxy" {
  description = "Put RDS Proxy in front of the instance (connection pooling; billed per vCPU of the instance, at least 2)"
  type        = bool
  default     = false
}
