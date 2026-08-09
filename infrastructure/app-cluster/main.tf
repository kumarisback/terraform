terraform {
  required_version = ">= 1.2"

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

  name                    = var.project_name
  environment             = var.environment
  vpc_id                  = module.networking.vpc_id
  vpc_cidr                = var.vpc_cidr
  private_data_subnet_ids = module.networking.private_data_subnet_ids
  enable_rds              = var.enable_rds
  enable_elasticache      = var.enable_elasticache
  redis_node_type         = var.redis_node_type
}

module "secrets" {
  source        = "../../modules/secrets"
  secret_name   = var.secret_name
  manage_secret = true
  secret_values = {
    REDIS_HOST = module.database.redis_endpoint
    REDIS_PORT = "6379"
  }
}

resource "aws_ssm_parameter" "rds_endpoint" {
  name  = "/${var.environment}/rds/endpoint"
  type  = "String"
  value = module.database.redis_endpoint # Using redis endpoint as placeholder for rds_endpoint since RDS is disabled by default in vars
}


provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  set {
    name  = "server.service.type"
    value = var.enable_argocd_loadbalancer ? "LoadBalancer" : "ClusterIP"
  }

  dynamic "set" {
    for_each = var.enable_argocd_loadbalancer ? var.argocd_allowed_cidrs : []
    content {
      name  = "server.service.loadBalancerSourceRanges[${set.key}]"
      value = set.value
    }
  }
}


