# terraform test for the module (run in modules/database: terraform init &&
# terraform test). The AWS provider is mocked: no credentials, nothing
# created, nothing billed.
mock_provider "aws" {
  mock_data "aws_rds_engine_version" {
    defaults = {
      parameter_group_family = "postgres17"
    }
  }

  # Security groups' ids at plan time, so the database's rules (one of them
  # naming the proxy's group) can be counted.
  mock_resource "aws_security_group" {
    override_during = plan
    defaults = {
      id = "sg-0fedcba9876543210"
    }
  }

  # The secret RDS creates is known only after the instance exists; the
  # mock supplies it at plan time, for the proxy test.
  mock_resource "aws_db_instance" {
    override_during = plan
    defaults = {
      identifier = "microservices-staging-rds"
      master_user_secret = [{
        kms_key_id    = "alias/aws/secretsmanager"
        secret_arn    = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-0b1c2d3e"
        secret_status = "active"
      }]
    }
  }
}

variables {
  name                          = "microservices"
  environment                   = "staging"
  vpc_id                        = "vpc-0123456789abcdef0"
  private_data_subnet_ids       = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
  client_security_group_ids     = ["sg-0123456789abcdef0"]
  enable_rds                    = true
  enable_elasticache            = true
  rds_final_snapshot_identifier = "microservices-staging-final"
}

run "only_the_engine_port_from_the_cluster" {
  command = plan

  assert {
    condition = length(aws_security_group.rds[0].ingress) == 1 && alltrue([
      for rule in aws_security_group.rds[0].ingress :
      rule.from_port == 5432 && rule.to_port == 5432 && rule.protocol == "tcp" &&
      toset(rule.security_groups) == toset(var.client_security_group_ids) &&
      try(length(rule.cidr_blocks), 0) == 0
    ])
    error_message = "PostgreSQL's port only, from the client security groups, no address ranges."
  }

  assert {
    condition = length(aws_security_group.redis[0].ingress) == 1 && alltrue([
      for rule in aws_security_group.redis[0].ingress :
      rule.from_port == 6379 && rule.to_port == 6379 && rule.protocol == "tcp" &&
      toset(rule.security_groups) == toset(var.client_security_group_ids) &&
      try(length(rule.cidr_blocks), 0) == 0
    ])
    error_message = "Redis's port only, from the client security groups, no address ranges."
  }
}

run "production_grade_postgres" {
  command = plan

  assert {
    condition = (
      aws_db_instance.rds[0].engine == "postgres" &&
      aws_db_instance.rds[0].multi_az &&
      aws_db_instance.rds[0].storage_encrypted &&
      aws_db_instance.rds[0].storage_type == "gp3" &&
      !aws_db_instance.rds[0].publicly_accessible &&
      aws_db_instance.rds[0].manage_master_user_password &&
      aws_db_instance.rds[0].iam_database_authentication_enabled &&
      aws_db_instance.rds[0].deletion_protection &&
      aws_db_instance.rds[0].performance_insights_enabled &&
      aws_db_instance.rds[0].monitoring_interval == 60
    )
    error_message = "Multi-AZ, encrypted gp3, private, a managed rotating password, IAM auth, deletion protection, Database Insights and Enhanced Monitoring."
  }

  assert {
    condition = alltrue([
      for p in ["rds.force_ssl", "rds.logical_replication"] :
      contains([for x in aws_db_parameter_group.rds[0].parameter : x.name if x.value == "1"], p)
    ])
    error_message = "The parameter group forces TLS and enables logical replication."
  }

  assert {
    condition     = toset(keys(aws_cloudwatch_metric_alarm.rds)) == toset(["cpu", "storage", "connections", "memory", "replication_slot_lag"])
    error_message = "Five alarms without a replica."
  }
}

run "a_replica_brings_its_lag_alarm" {
  command = plan

  variables {
    rds_read_replica = true
  }

  assert {
    condition     = length(aws_db_instance.rds_replica) == 1 && contains(keys(aws_cloudwatch_metric_alarm.rds), "replica_lag")
    error_message = "A read replica and an alarm on its lag."
  }
}

run "a_proxy_between_clients_and_database" {
  command = plan

  variables {
    rds_proxy = true
  }

  assert {
    condition = (
      aws_db_proxy.rds[0].require_tls &&
      aws_db_proxy.rds[0].engine_family == "POSTGRESQL" &&
      one(aws_db_proxy.rds[0].auth).secret_arn == aws_db_instance.rds[0].master_user_secret[0].secret_arn &&
      length(aws_db_proxy_target.rds) == 1
    )
    error_message = "A TLS-only proxy signing in with the managed secret, targeting the instance."
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.rds_proxy_clients) == length(var.client_security_group_ids) &&
      aws_vpc_security_group_egress_rule.rds_proxy_database[0].from_port == 5432 &&
      length(aws_security_group.rds[0].ingress) == 2
    )
    error_message = "Clients reach the proxy, the proxy reaches the database, on 5432 only."
  }
}

run "no_proxy_without_the_managed_secret" {
  command = plan

  variables {
    rds_proxy                       = true
    rds_manage_master_user_password = false
    rds_password                    = "only-in-this-test"
  }

  expect_failures = [aws_db_proxy.rds]
}

run "refuses_mysql" {
  command = plan

  variables {
    rds_engine = "mysql"
  }

  expect_failures = [var.rds_engine]
}

run "refuses_no_clients" {
  command = plan

  variables {
    client_security_group_ids = []
  }

  expect_failures = [var.client_security_group_ids]
}
