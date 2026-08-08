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

# VPC/Networking for shared services
module "networking" {
  source = "../../modules/networking"

  name                      = var.project_name
  environment               = var.environment
  cidr_block                = var.vpc_cidr
  public_subnet_cidrs       = var.public_subnet_cidrs
  private_app_subnet_cidrs  = var.private_app_subnet_cidrs
  private_data_subnet_cidrs = var.private_data_subnet_cidrs
  enable_nat_gateway        = var.enable_nat_gateway
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
  vpc_id              = module.networking.vpc_id
  subnet_id           = module.networking.public_subnet_ids[0]
  instance_type       = var.jenkins_instance_type
  allowed_cidr_blocks = var.jenkins_allowed_cidrs
}
