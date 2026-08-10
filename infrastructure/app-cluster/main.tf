terraform {
  required_version = ">= 1.2"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.92"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
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
  admin_users           = var.eks_admin_users
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

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

resource "helm_release" "argocd" {
  # During apply: Wait for EKS and any sleep buffer
  # During destroy: Uninstall helm chart BEFORE starting the EKS cluster deletion
  depends_on = [time_sleep.wait_for_lb_cleanup]

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.15"
  namespace        = "argocd"
  create_namespace = true


  set = concat(
    [
      {
        name  = "server.service.type"
        value = var.enable_argocd_loadbalancer ? "LoadBalancer" : "ClusterIP"
      }
    ],
    var.enable_argocd_loadbalancer ? [
      for idx, cidr in var.argocd_allowed_cidrs : {
        name  = "server.service.loadBalancerSourceRanges[${idx}]"
        value = cidr
      }
    ] : []
  )
}

# Introducing a sleep during destroy to allow AWS to delete the Load Balancer
# and detach any network interfaces (ENIs) before the EKS cluster goes offline.
resource "time_sleep" "wait_for_lb_cleanup" {
  depends_on = [module.eks]

  # No delay when creating the EKS cluster/controllers
  create_duration = "0s"

  # Wait 2 minutes during destroy before starting the EKS cluster deletion
  destroy_duration = "120s"
}

resource "kubernetes_manifest" "argocd_root_app" {
  depends_on = [helm_release.argocd]

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root-app"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_gitops_repo_url
        targetRevision = var.argocd_gitops_repo_revision
        path           = var.argocd_gitops_repo_path
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  }
}




