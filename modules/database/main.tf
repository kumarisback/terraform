locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.name
  }
}

# Security Group for RDS
resource "aws_security_group" "rds" {
  count       = var.enable_rds ? 1 : 0
  name        = "${var.name}-${var.environment}-rds-sg"
  description = "Allow database traffic from within the VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "PostgreSQL access from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "MySQL access from VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-rds-sg"
  })
}

# Security Group for Redis
resource "aws_security_group" "redis" {
  count       = var.enable_elasticache ? 1 : 0
  name        = "${var.name}-${var.environment}-redis-sg"
  description = "Allow Redis traffic from within the VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "Redis access from VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-redis-sg"
  })
}

# ElastiCache Subnet Group
resource "aws_elasticache_subnet_group" "redis" {
  count      = var.enable_elasticache ? 1 : 0
  name       = "${var.name}-${var.environment}-redis-subnet-group"
  subnet_ids = var.private_data_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-redis-subnet-group"
  })
}

# ElastiCache Redis Cluster
resource "aws_elasticache_cluster" "redis" {
  count                = var.enable_elasticache ? 1 : 0
  cluster_id           = "${var.name}-${var.environment}-redis"
  engine               = "redis"
  node_type            = var.redis_node_type
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.0"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.redis[0].name
  security_group_ids = [aws_security_group.redis[0].id]

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-redis"
  })
}

# RDS subnet group for database instances
resource "aws_db_subnet_group" "rds" {
  count      = var.enable_rds ? 1 : 0
  name       = "${var.name}-${var.environment}-rds-subnet-group"
  subnet_ids = var.private_data_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-rds-subnet-group"
  })
}

# RDS database instance
resource "aws_db_instance" "rds" {
  count                       = var.enable_rds ? 1 : 0
  identifier                  = "${var.name}-${var.environment}-rds"
  engine                      = var.rds_engine
  engine_version              = var.rds_engine_version
  instance_class              = var.rds_instance_class
  allocated_storage           = var.rds_allocated_storage
  db_subnet_group_name        = aws_db_subnet_group.rds[0].name
  vpc_security_group_ids      = [aws_security_group.rds[0].id]
  username                    = var.rds_username
  password                    = var.rds_manage_master_user_password ? null : var.rds_password
  manage_master_user_password = var.rds_manage_master_user_password
  db_name                     = var.rds_db_name
  storage_encrypted           = var.rds_storage_encrypted
  backup_retention_period     = var.rds_backup_retention_period
  skip_final_snapshot         = var.rds_skip_final_snapshot
  final_snapshot_identifier   = var.rds_skip_final_snapshot ? null : var.rds_final_snapshot_identifier
  publicly_accessible         = false
  deletion_protection         = var.rds_deletion_protection
  apply_immediately           = var.rds_apply_immediately

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-rds"
  })

  lifecycle {
    precondition {
      condition     = var.rds_manage_master_user_password || var.rds_password != null
      error_message = "Set rds_password when rds_manage_master_user_password is false."
    }

    precondition {
      condition     = var.rds_skip_final_snapshot || var.rds_final_snapshot_identifier != null
      error_message = "Set rds_final_snapshot_identifier when rds_skip_final_snapshot is false."
    }
  }
}
