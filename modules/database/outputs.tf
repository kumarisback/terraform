output "redis_endpoint" {
  description = "Redis primary endpoint address"
  value       = var.enable_elasticache ? aws_elasticache_cluster.redis[0].cache_nodes[0].address : null
}

output "redis_security_group_id" {
  description = "Redis security group ID"
  value       = var.enable_elasticache ? aws_security_group.redis[0].id : null
}

output "rds_security_group_id" {
  description = "RDS security group ID"
  value       = var.enable_rds ? aws_security_group.rds[0].id : null
}

output "rds_endpoint" {
  description = "RDS database endpoint"
  value       = var.enable_rds ? aws_db_instance.rds[0].endpoint : null
}

output "rds_address" {
  description = "PostgreSQL's host name (null while enable_rds is off)"
  value       = var.enable_rds ? aws_db_instance.rds[0].address : null
}

output "rds_port" {
  description = "PostgreSQL's port"
  value       = var.enable_rds ? aws_db_instance.rds[0].port : null
}

output "rds_db_name" {
  description = "The database RDS created"
  value       = var.enable_rds ? aws_db_instance.rds[0].db_name : null
}

output "rds_master_secret_arn" {
  description = "The Secrets Manager secret RDS keeps the master user's credentials in (JSON: username, password), rotated by RDS"
  value       = var.enable_rds && var.rds_manage_master_user_password ? aws_db_instance.rds[0].master_user_secret[0].secret_arn : null
}

output "rds_replica_address" {
  description = "The read replica's host name, if any"
  value       = var.enable_rds && var.rds_read_replica ? aws_db_instance.rds_replica[0].address : null
}

output "rds_proxy_address" {
  description = "RDS Proxy's host name, if any: clients connect here instead of rds_address"
  value       = var.enable_rds && var.rds_proxy ? aws_db_proxy.rds[0].endpoint : null
}
