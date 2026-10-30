# terraform test for the module (run in modules/msk: terraform init &&
# terraform test). The AWS provider is mocked: no credentials, nothing
# created, nothing billed. The IAM policies in 01-infra msk.tf are built
# from the ARN prefixes checked here.
mock_provider "aws" {
  mock_resource "aws_msk_serverless_cluster" {
    defaults = {
      arn = "arn:aws:kafka:us-east-1:123456789012:cluster/microservices-dev-events/0b1c2d3e-1111-2222-3333-444455556666-s1"
    }
  }

  mock_data "aws_msk_bootstrap_brokers" {
    defaults = {
      bootstrap_brokers_sasl_iam = "boot-abc123.c1.kafka-serverless.us-east-1.amazonaws.com:9098"
    }
  }
}

variables {
  name               = "microservices"
  environment        = "dev"
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_ids         = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
  client_cidr_blocks = ["10.0.11.0/24", "10.0.12.0/24"]
}

run "iam_only_and_policy_names" {
  command = apply

  assert {
    condition     = aws_msk_serverless_cluster.this.client_authentication[0].sasl[0].iam[0].enabled
    error_message = "The cluster must accept IAM authentication."
  }

  assert {
    condition     = output.topic_arn_prefix == "arn:aws:kafka:us-east-1:123456789012:topic/microservices-dev-events/0b1c2d3e-1111-2222-3333-444455556666-s1"
    error_message = "Topic ARNs are the cluster ARN with :cluster/ replaced by :topic/."
  }

  assert {
    condition     = output.group_arn_prefix == "arn:aws:kafka:us-east-1:123456789012:group/microservices-dev-events/0b1c2d3e-1111-2222-3333-444455556666-s1"
    error_message = "Group ARNs are the cluster ARN with :cluster/ replaced by :group/."
  }

  assert {
    condition     = output.bootstrap_brokers_sasl_iam == "boot-abc123.c1.kafka-serverless.us-east-1.amazonaws.com:9098"
    error_message = "The bootstrap output must be the IAM endpoint."
  }
}

run "only_kafka_with_iam_from_the_pod_subnets" {
  command = plan

  assert {
    condition = length(aws_security_group.msk.ingress) == 1 && alltrue([
      for rule in aws_security_group.msk.ingress :
      rule.from_port == 9098 && rule.to_port == 9098 && rule.protocol == "tcp" &&
      toset(rule.cidr_blocks) == toset(var.client_cidr_blocks)
    ])
    error_message = "The only way in is 9098/tcp from the client CIDR blocks."
  }
}

run "refuses_a_single_subnet" {
  command = plan

  variables {
    subnet_ids = ["subnet-0aaaaaaaaaaaaaaaa"]
  }

  expect_failures = [var.subnet_ids]
}
