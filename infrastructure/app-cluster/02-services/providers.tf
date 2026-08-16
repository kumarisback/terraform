# terraform {
#   required_version = ">= 1.12, < 2.0"

#   backend "s3" {}

#   required_providers {
#     aws = {
#       source  = "hashicorp/aws"
#       version = "~> 5.92"
#     }
#     helm = {
#       source  = "hashicorp/helm"
#       version = "~> 3.0"
#     }
#     time = {
#       source  = "hashicorp/time"
#       version = "~> 0.9"
#     }
#   }
# }

# provider "aws" {
#   region = var.aws_region
# }

# # Pull cluster outputs from Layer 1 state
# data "terraform_remote_state" "infra" {
#   backend = "s3"
#   config = {
#     bucket = var.s3_bucket
#     key    = "${var.environment}/infrastructure.tfstate"
#     region = var.aws_region
#   }
# }

# provider "helm" {
#   kubernetes = {
#     host                   = data.terraform_remote_state.infra.outputs.cluster_endpoint
#     cluster_ca_certificate = base64decode(data.terraform_remote_state.infra.outputs.cluster_certificate_authority_data)

#     exec = {
#       api_version = "client.authentication.k8s.io/v1beta1"
#       args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.infra.outputs.cluster_name]
#       command     = "aws"
#     }
#   }
# }

# # Configure Kubernetes provider using EKS cluster outputs
# provider "kubernetes" {
#   host                   = data.terraform_remote_state.infra.outputs.cluster_endpoint
#   cluster_ca_certificate = base64decode(data.terraform_remote_state.infra.outputs.cluster_certificate_authority_data)

#   exec {
#     api_version = "client.authentication.k8s.io/v1beta1"
#     command     = "aws"
#     args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.infra.outputs.cluster_name]
#   }
# }

provider "aws" {
  region = var.aws_region
}

# Pull cluster outputs from Layer 1 state
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = var.s3_bucket
    key    = "${var.environment}/infrastructure.tfstate"
    region = var.aws_region
  }
}

# Simplify Helm Provider to read local kubeconfig directly.
# pathexpand() is required here: Terraform does not shell-expand "~" in a
# plain string, so a bare "~/.kube/config" is treated as a literal relative
# path (a directory named "~") and never resolves — that's what was causing
# "Kubernetes cluster unreachable" on every Layer 2 apply.
provider "helm" {
  kubernetes = {
    config_path = pathexpand("~/.kube/config")
  }
}

# Simplify Kubernetes Provider to read local kubeconfig directly
provider "kubernetes" {
  config_path = pathexpand("~/.kube/config")
}
