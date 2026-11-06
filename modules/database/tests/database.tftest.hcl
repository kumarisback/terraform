# terraform test for the module (run in modules/database: terraform init &&
# terraform test). The AWS provider is mocked: no credentials, nothing
# created, nothing billed.
mock_provider "aws" {}

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
      rule.from_port == 3306 && rule.to_port == 3306 && rule.protocol == "tcp" &&
      toset(rule.security_groups) == toset(var.client_security_group_ids) &&
      try(length(rule.cidr_blocks), 0) == 0
    ])
    error_message = "MySQL's port only, from the client security groups, no address ranges."
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

run "postgres_gets_its_own_port" {
  command = plan

  variables {
    rds_engine         = "postgres"
    rds_engine_version = "17"
  }

  assert {
    condition     = one(aws_security_group.rds[0].ingress).from_port == 5432
    error_message = "PostgreSQL listens on 5432."
  }
}

run "refuses_no_clients" {
  command = plan

  variables {
    client_security_group_ids = []
  }

  expect_failures = [var.client_security_group_ids]
}
