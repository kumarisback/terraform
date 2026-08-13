terraform {
  required_version = ">= 1.12, < 2.0"

  backend "s3" {}

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


# ---------------------------------------------------------
# Shared VPC / Networking
# ---------------------------------------------------------

module "networking" {
  source = "../../modules/networking"

  name        = var.project_name
  environment = var.environment

  cidr_block = var.vpc_cidr

  public_subnet_cidrs = var.public_subnet_cidrs

  private_app_subnet_cidrs = var.private_app_subnet_cidrs

  private_data_subnet_cidrs = var.private_data_subnet_cidrs

  enable_nat_gateway = var.enable_nat_gateway
}


# ---------------------------------------------------------
# ECR repositories for all microservices
# ---------------------------------------------------------

module "ecr" {
  source = "../../modules/ecr"

  name         = var.project_name
  environment  = var.environment
  repositories = var.ecr_repositories
}


# ---------------------------------------------------------
# Jenkins CI/CD server
# ---------------------------------------------------------

module "jenkins" {
  source = "../../modules/jenkins"

  name        = var.project_name
  environment = var.environment

  # Jenkins now uses the VPC created by this
  # shared-services Terraform configuration.
  vpc_id = module.networking.vpc_id

  # Private subnet — no public IP, no inbound exposure. Outbound internet
  # access (for package installs) goes through the NAT gateway; inbound
  # access is via `aws ssm start-session` (see README.md).
  subnet_id = module.networking.private_app_subnet_ids[0]

  instance_type              = var.jenkins_instance_type
  allowed_cidr_blocks        = var.jenkins_allowed_cidrs
  terraform_deploy_role_arns = var.jenkins_terraform_deploy_role_arns
  state_bucket_names         = var.terraform_state_bucket_names
  managed_environments       = var.managed_environments
}
