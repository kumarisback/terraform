# ---------------------------------------------------------
# Amazon MSK Serverless (roadmap step 14): Kafka run by AWS, the managed
# alternative to the Strimzi cluster in gitops streaming/.
#
# Serverless has no brokers to size: AWS scales it, keeps three copies of
# every partition across zones, and encrypts at rest and in transit. It
# accepts only IAM authentication (SASL/IAM over TLS, port 9098): a client
# signs in with its AWS credentials and IAM policies play the part of
# Kafka ACLs. Billed per cluster-hour, partition-hour and GB in and out.
# ---------------------------------------------------------
locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.name
  }
}

# Clients reach the cluster's endpoints, which MSK places in the subnets
# below, on 9098 from the pod subnets. MSK never opens connections itself,
# so no egress.
resource "aws_security_group" "msk" {
  name        = "${var.name}-${var.environment}-msk-sg"
  description = "Kafka clients (SASL/IAM over TLS) to MSK Serverless"
  vpc_id      = var.vpc_id

  ingress {
    description = "Kafka, IAM authentication"
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = var.client_cidr_blocks
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-msk-sg"
  })
}

resource "aws_msk_serverless_cluster" "this" {
  cluster_name = "${var.name}-${var.environment}-events"

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.msk.id]
  }

  client_authentication {
    sasl {
      iam {
        enabled = true
      }
    }
  }

  tags = local.common_tags
}

data "aws_msk_bootstrap_brokers" "this" {
  cluster_arn = aws_msk_serverless_cluster.this.arn
}
