# Terraform Infrastructure Repository

This repository contains the Terraform code for provisioning the cloud infrastructure required by the Kubernetes-based application stack.

## What is included

- VPC and networking resources
- Security groups
- ECR repositories
- RDS database resources
- ElastiCache resources
- IAM roles and policies for EKS
- EKS cluster configuration
- OIDC provider setup
- ALB controller and external secrets IRSA setup
- Secrets Manager integration

## Main files

- 00-providers.tf — provider configuration
- 01-vpc.tf — VPC and subnets
- 02-security-groups.tf — network access rules
- 03-ecr.tf — container registry resources
- 04-rds.tf — database infrastructure
- 05-elasticache.tf — cache infrastructure
- 06-iam-eks.tf — IAM roles for EKS
- 07-eks-cluster.tf — EKS cluster definition
- 08-oidc-provider.tf — OIDC provider setup
- 09-alb-controller-irsa.tf — IAM role for ALB controller
- 10-external-secrets-irsa.tf — IAM role for external-secrets
- 11-secrets-manager.tf — Secrets Manager resources

## Typical workflow

1. Review the Terraform variables and provider configuration.
2. Run terraform init to initialize the working directory.
3. Run terraform plan to review the intended infrastructure changes.
4. Run terraform apply to create or update the resources.

## Purpose in the full stack

This repository provides the underlying cloud resources so the DevOps and GitOps repositories can deploy applications into a working Kubernetes environment.
