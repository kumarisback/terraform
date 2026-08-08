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
