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

module "eks" {
  source = "../../modules/eks"

  name                  = var.project_name
  environment           = var.environment
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_app_subnet_ids
  cluster_version       = var.cluster_version
  node_desired_capacity = var.node_desired_capacity
  node_min_capacity     = var.node_min_capacity
  node_max_capacity     = var.node_max_capacity
  node_instance_type    = var.node_instance_type
}

module "database" {
  source = "../../modules/database"

  name                  = var.project_name
  environment           = var.environment
  vpc_id                = module.networking.vpc_id
  vpc_cidr              = var.vpc_cidr
  private_data_subnet_ids = module.networking.private_data_subnet_ids
  enable_rds            = var.enable_rds
  enable_elasticache    = var.enable_elasticache
  redis_node_type       = var.redis_node_type
}

module "secrets" {
  source       = "../../modules/secrets"
  secret_name  = var.secret_name
  manage_secret = true
  secret_values = {
    MONGO_URI = ""
    REDIS_HOST = module.database.redis_endpoint
    REDIS_PORT = "6379"
    JWT_SECRET = ""
  }
}
