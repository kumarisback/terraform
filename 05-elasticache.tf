# 1. ElastiCache Subnet Group (Restricted to Private Data Subnets)
resource "aws_elasticache_subnet_group" "redis" {
  name       = "microservices-redis-subnet-group"
  subnet_ids = aws_subnet.private_data[*].id

  tags = {
    Name = "microservices-redis-subnet-group"
  }
}

# 2. ElastiCache Redis Cluster (Single Node for Dev/Learning)
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "microservices-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.0"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  tags = {
    Name = "microservices-redis"
  }
}

# 3. Output Redis Host / Endpoint
output "redis_endpoint" {
  description = "Primary endpoint address for the Redis Cluster"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}