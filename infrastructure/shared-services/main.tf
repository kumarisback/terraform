terraform {
  required_version = ">= 1.2"

  # backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.92"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = var.project_name
    }
  }
}

# Read outputs from the existing dev environment so Jenkins uses the dev VPC/subnets

# S3 remote state (used when use_local_state == false)
data "terraform_remote_state" "dev_s3" {
  count   = var.use_local_state ? 0 : 1
  backend = "s3"
  config = {
    bucket         = var.dev_state_bucket
    key            = var.dev_state_key
    region         = var.dev_state_region
    dynamodb_table = var.dev_state_dynamodb_table
    encrypt        = true
  }
}

# Local state file (used when use_local_state == true)
data "terraform_remote_state" "dev_local" {
  count   = var.use_local_state ? 1 : 0
  backend  = "local"
  config = {
    path = var.dev_state_path
  }
}

locals {
  dev_state = var.use_local_state ? data.terraform_remote_state.dev_local[0] : data.terraform_remote_state.dev_s3[0]
}

# ECR repositories for all microservices
module "ecr" {
  source = "../../modules/ecr"

  name         = var.project_name
  environment  = var.environment
  repositories = var.ecr_repositories
}

# Jenkins CI/CD server
module "jenkins" {
  source = "../../modules/jenkins"

  name                = var.project_name
  environment         = var.environment
  vpc_id              = local.dev_state.outputs.vpc_id
  subnet_id           = local.dev_state.outputs.public_subnet_ids[0]
  instance_type       = var.jenkins_instance_type
  allowed_cidr_blocks = var.jenkins_allowed_cidrs
}
