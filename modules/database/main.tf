locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.name
  }

  # The engine's own port, nothing else.
  rds_port = strcontains(var.rds_engine, "postgres") ? 5432 : 3306
}

# Who may connect: the security groups given (the EKS cluster's, which the
# nodes and so every pod carry), not every address in the VPC. Learning
# topic 19. No egress rules: a database answers connections, it doesn't
# open any, and security groups let the answers out on their own.
#
# The descriptions still say "from within the VPC": a group's description
# can't change without replacing the group, and a running database holds on
# to its group, so the replacement would fail. The rules are what count.

# Security Group for RDS
resource "aws_security_group" "rds" {
  count       = var.enable_rds ? 1 : 0
  name        = "${var.name}-${var.environment}-rds-sg"
  description = "Allow database traffic from within the VPC"
  vpc_id      = var.vpc_id

  ingress {
    description     = "${var.rds_engine} from the client security groups"
    from_port       = local.rds_port
    to_port         = local.rds_port
    protocol        = "tcp"
    security_groups = var.client_security_group_ids
  }

  # And from RDS Proxy, when there is one.
  dynamic "ingress" {
    for_each = var.rds_proxy ? [1] : []
    content {
      description     = "${var.rds_engine} from RDS Proxy"
      from_port       = local.rds_port
      to_port         = local.rds_port
      protocol        = "tcp"
      security_groups = [aws_security_group.rds_proxy[0].id]
    }
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
    description     = "Redis from the client security groups"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = var.client_security_group_ids
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

# ---------------------------------------------------------
# PostgreSQL on RDS, production-grade (roadmap step 23, learning topic 23).
# What each setting buys is explained where it is set; the module serves
# PostgreSQL only since then (the parameter group is PostgreSQL's).
# ---------------------------------------------------------
data "aws_rds_engine_version" "rds" {
  count   = var.enable_rds ? 1 : 0
  engine  = var.rds_engine
  version = var.rds_engine_version
  latest  = true
}

# Settings the defaults don't give: TLS refused never (the default since
# PostgreSQL 15, written down so a default can't change it), logical
# replication for change data capture (Debezium, roadmap step 23), and every
# statement slower than half a second in the log, for finding slow queries.
resource "aws_db_parameter_group" "rds" {
  count  = var.enable_rds ? 1 : 0
  name   = "${var.name}-${var.environment}-postgres"
  family = data.aws_rds_engine_version.rds[0].parameter_group_family

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  tags = local.common_tags

  # A changed family makes a new group; the instance moves to it first.
  lifecycle {
    create_before_destroy = true
  }
}

# Enhanced Monitoring: the operating system's view (processes, memory,
# disk), every minute, from an agent RDS runs; it writes to CloudWatch Logs
# with this role.
resource "aws_iam_role" "rds_monitoring" {
  count = var.enable_rds && var.rds_monitoring_interval > 0 ? 1 : 0
  name  = "${var.name}-${var.environment}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count      = var.enable_rds && var.rds_monitoring_interval > 0 ? 1 : 0
  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "rds" {
  count          = var.enable_rds ? 1 : 0
  identifier     = "${var.name}-${var.environment}-rds"
  engine         = var.rds_engine
  engine_version = var.rds_engine_version
  # Minor versions (security fixes) in the maintenance window.
  auto_minor_version_upgrade = true
  instance_class             = var.rds_instance_class
  port                       = local.rds_port
  parameter_group_name       = aws_db_parameter_group.rds[0].name

  # A synchronous standby in another zone: a lost zone or instance fails
  # over to it in a minute or two, same endpoint. Not a read replica: the
  # standby takes no queries.
  multi_az = var.rds_multi_az

  # gp3, growing on its own up to max_allocated_storage instead of filling up.
  storage_type          = "gp3"
  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage
  storage_encrypted     = var.rds_storage_encrypted

  db_subnet_group_name   = aws_db_subnet_group.rds[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]
  publicly_accessible    = false
  # The CA the server's certificate is signed by; clients verify against
  # AWS's bundle (truststore.pki.rds.amazonaws.com).
  ca_cert_identifier = var.rds_ca_cert_identifier

  username = var.rds_username
  password = var.rds_manage_master_user_password ? null : var.rds_password
  # The password lives in a Secrets Manager secret RDS creates and rotates
  # (every 7 days by default); nobody, Terraform included, sees it. Null,
  # not false, when off: the provider refuses the argument next to password
  # even when it is false.
  manage_master_user_password = var.rds_manage_master_user_password ? true : null
  # Users may also sign in with IAM tokens instead of passwords.
  iam_database_authentication_enabled = true
  db_name                             = var.rds_db_name

  # Point-in-time recovery within the retention, and a last snapshot if the
  # instance is ever deleted.
  backup_retention_period   = var.rds_backup_retention_period
  copy_tags_to_snapshot     = true
  skip_final_snapshot       = var.rds_skip_final_snapshot
  final_snapshot_identifier = var.rds_skip_final_snapshot ? null : var.rds_final_snapshot_identifier
  deletion_protection       = var.rds_deletion_protection
  apply_immediately         = var.rds_apply_immediately

  # What the database spends its time on (Database Insights, standard mode:
  # 7 days kept, free), the OS's view, and its logs in CloudWatch Logs.
  performance_insights_enabled          = var.rds_performance_insights_enabled
  performance_insights_retention_period = var.rds_performance_insights_enabled ? 7 : null
  database_insights_mode                = var.rds_performance_insights_enabled ? "standard" : null
  monitoring_interval                   = var.rds_monitoring_interval
  monitoring_role_arn                   = var.rds_monitoring_interval > 0 ? aws_iam_role.rds_monitoring[0].arn : null
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

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

# A read replica: asynchronous, readable, for read scaling (or a reporting
# copy). Off by default: nothing here routes reads to one (learning topic 23
# says when it would).
resource "aws_db_instance" "rds_replica" {
  count                      = var.enable_rds && var.rds_read_replica ? 1 : 0
  identifier                 = "${var.name}-${var.environment}-rds-replica"
  replicate_source_db        = aws_db_instance.rds[0].identifier
  instance_class             = var.rds_instance_class
  parameter_group_name       = aws_db_parameter_group.rds[0].name
  vpc_security_group_ids     = [aws_security_group.rds[0].id]
  publicly_accessible        = false
  ca_cert_identifier         = var.rds_ca_cert_identifier
  auto_minor_version_upgrade = true
  storage_encrypted          = var.rds_storage_encrypted
  max_allocated_storage      = var.rds_max_allocated_storage

  performance_insights_enabled          = var.rds_performance_insights_enabled
  performance_insights_retention_period = var.rds_performance_insights_enabled ? 7 : null
  monitoring_interval                   = var.rds_monitoring_interval
  monitoring_role_arn                   = var.rds_monitoring_interval > 0 ? aws_iam_role.rds_monitoring[0].arn : null

  # Replicas have no backups of their own and take no final snapshot.
  skip_final_snapshot = true
  apply_immediately   = var.rds_apply_immediately

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-rds-replica"
  })
}

# ---------------------------------------------------------
# Alarms (CloudWatch: RDS publishes these on its own), to alarm_actions.
# ---------------------------------------------------------
locals {
  rds_alarms = !var.enable_rds ? {} : merge(
    {
      cpu = {
        metric      = "CPUUtilization", comparison = "GreaterThanThreshold", threshold = 80, periods = 3
        description = "CPU above 80% for 15 minutes: slow queries (Database Insights' top SQL) or a class too small."
        instance    = aws_db_instance.rds[0].identifier
      }
      storage = {
        metric      = "FreeStorageSpace", comparison = "LessThanThreshold", threshold = 2 * 1024 * 1024 * 1024, periods = 1
        description = "Under 2 GiB free: storage grows on its own up to max_allocated_storage, so check that limit."
        instance    = aws_db_instance.rds[0].identifier
      }
      connections = {
        metric      = "DatabaseConnections", comparison = "GreaterThanThreshold", threshold = var.rds_connections_alarm_threshold, periods = 2
        description = "Connections near max_connections: a client's pool too large, or too many replicas of it (learning topic 23, connection pooling)."
        instance    = aws_db_instance.rds[0].identifier
      }
      memory = {
        metric      = "FreeableMemory", comparison = "LessThanThreshold", threshold = 64 * 1024 * 1024, periods = 3
        description = "Under 64 MiB of freeable memory: the instance class is too small for the load."
        instance    = aws_db_instance.rds[0].identifier
      }
      # A replication slot keeps every bit of write-ahead log its reader
      # hasn't confirmed: a stopped Debezium fills the disk, slowly.
      replication_slot_lag = {
        metric      = "OldestReplicationSlotLag", comparison = "GreaterThanThreshold", threshold = 1024 * 1024 * 1024, periods = 3
        description = "A replication slot holds over 1 GiB of write-ahead log: its reader (Debezium, connector flag-changes) is stopped or behind. Restart it, or drop the slot if it is gone for good."
        instance    = aws_db_instance.rds[0].identifier
      }
    },
    var.rds_read_replica ? {
      replica_lag = {
        metric      = "ReplicaLag", comparison = "GreaterThanThreshold", threshold = 60, periods = 3
        description = "The read replica is more than a minute behind: reads from it are stale."
        instance    = aws_db_instance.rds_replica[0].identifier
      }
    } : {}
  )
}

resource "aws_cloudwatch_metric_alarm" "rds" {
  for_each = local.rds_alarms

  alarm_name          = "${var.name}-${var.environment}-rds-${each.key}"
  alarm_description   = "${each.value.description} Runbook: learning topic 23."
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = each.value.instance }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = each.value.periods
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  treat_missing_data  = "missing"
  alarm_actions       = var.alarm_actions
  ok_actions          = var.alarm_actions

  tags = local.common_tags
}

# ---------------------------------------------------------
# RDS Proxy (optional): a pool of database connections that clients share.
# PostgreSQL gives each connection a process and a few MB of memory, and
# db.t4g.micro allows about 80; pods times their pool sizes passes that
# quickly when something scales out. Clients connect to the proxy instead
# (same port, same user and password, TLS required) and it multiplexes them
# onto a few connections to the instance; it also hides a Multi-AZ failover
# from them better than DNS does. Learning topic 23 compares it with
# PgBouncer. Change data capture (logical replication) can't go through it:
# Debezium connects to the instance itself.
# ---------------------------------------------------------
resource "aws_security_group" "rds_proxy" {
  count       = var.enable_rds && var.rds_proxy ? 1 : 0
  name        = "${var.name}-${var.environment}-rds-proxy-sg"
  description = "RDS Proxy: the clients in, the database out"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-rds-proxy-sg"
  })
}

# Rules of their own (the group has no inline ones): the proxy's group and
# the database's refer to each other.
resource "aws_vpc_security_group_ingress_rule" "rds_proxy_clients" {
  count                        = var.enable_rds && var.rds_proxy ? length(var.client_security_group_ids) : 0
  security_group_id            = aws_security_group.rds_proxy[0].id
  description                  = "${var.rds_engine} from a client security group"
  referenced_security_group_id = var.client_security_group_ids[count.index]
  ip_protocol                  = "tcp"
  from_port                    = local.rds_port
  to_port                      = local.rds_port
}

resource "aws_vpc_security_group_egress_rule" "rds_proxy_database" {
  count                        = var.enable_rds && var.rds_proxy ? 1 : 0
  security_group_id            = aws_security_group.rds_proxy[0].id
  description                  = "${var.rds_engine} to the database"
  referenced_security_group_id = aws_security_group.rds[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.rds_port
  to_port                      = local.rds_port
}

# The proxy signs in to the database with the master user's secret, so it
# may read that secret (and decrypt it, through Secrets Manager only).
resource "aws_iam_role" "rds_proxy" {
  count = var.enable_rds && var.rds_proxy ? 1 : 0
  name  = "${var.name}-${var.environment}-rds-proxy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "rds_proxy" {
  count = var.enable_rds && var.rds_proxy ? 1 : 0
  name  = "read-master-secret"
  role  = aws_iam_role.rds_proxy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_db_instance.rds[0].master_user_secret[0].secret_arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_db_instance.rds[0].master_user_secret[0].kms_key_id
        Condition = {
          StringEquals = { "kms:ViaService" = "secretsmanager.${split(":", aws_db_instance.rds[0].master_user_secret[0].secret_arn)[3]}.amazonaws.com" }
        }
      }
    ]
  })
}

resource "aws_db_proxy" "rds" {
  count          = var.enable_rds && var.rds_proxy ? 1 : 0
  name           = "${var.name}-${var.environment}-rds-proxy"
  engine_family  = "POSTGRESQL"
  role_arn       = aws_iam_role.rds_proxy[0].arn
  vpc_subnet_ids = var.private_data_subnet_ids
  # Clients must use TLS; the proxy's certificate is from ACM (Amazon's
  # public roots), not the RDS CA.
  require_tls            = true
  vpc_security_group_ids = [aws_security_group.rds_proxy[0].id]
  # A client connection idle this long is closed (the pool behind it isn't).
  idle_client_timeout = 1800

  auth {
    auth_scheme               = "SECRETS"
    secret_arn                = aws_db_instance.rds[0].master_user_secret[0].secret_arn
    client_password_auth_type = "POSTGRES_SCRAM_SHA_256"
    iam_auth                  = "DISABLED"
    description               = "The master user, from the secret RDS rotates"
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = var.rds_manage_master_user_password
      error_message = "rds_proxy signs in with the secret RDS manages: set rds_manage_master_user_password."
    }
  }
}

resource "aws_db_proxy_default_target_group" "rds" {
  count         = var.enable_rds && var.rds_proxy ? 1 : 0
  db_proxy_name = aws_db_proxy.rds[0].name

  connection_pool_config {
    # Of the instance's max_connections, leaving some for people and
    # Debezium, who connect to the instance directly.
    max_connections_percent      = 75
    max_idle_connections_percent = 25
    # How long a client waits for a free connection before an error.
    connection_borrow_timeout = 30
  }
}

resource "aws_db_proxy_target" "rds" {
  count                  = var.enable_rds && var.rds_proxy ? 1 : 0
  db_proxy_name          = aws_db_proxy.rds[0].name
  target_group_name      = aws_db_proxy_default_target_group.rds[0].name
  db_instance_identifier = aws_db_instance.rds[0].identifier
}
