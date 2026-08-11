variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "microservices"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, or prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.10.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.10.1.0/24", "10.10.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "CIDR blocks for private application subnets"
  type        = list(string)
  default     = ["10.10.11.0/24", "10.10.12.0/24"]
}

variable "private_data_subnet_cidrs" {
  description = "CIDR blocks for private data subnets"
  type        = list(string)
  default     = ["10.10.21.0/24", "10.10.22.0/24"]
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway"
  type        = bool
  default     = true
}

variable "cluster_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.36"
}

variable "eks_endpoint_public_access" {
  description = "Whether to expose the EKS Kubernetes API endpoint publicly."
  type        = bool
  default     = false
}

variable "eks_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS Kubernetes API endpoint. Use your public IP/VPN CIDR, not 0.0.0.0/0."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.eks_public_access_cidrs, "0.0.0.0/0")
    error_message = "Do not expose the EKS API endpoint to 0.0.0.0/0. Use your public IP/VPN CIDR instead."
  }
}

variable "node_desired_capacity" {
  description = "Desired number of EKS worker nodes"
  type        = number
  default     = 2
}

variable "node_min_capacity" {
  description = "Minimum number of EKS worker nodes"
  type        = number
  default     = 1
}

variable "node_max_capacity" {
  description = "Maximum number of EKS worker nodes"
  type        = number
  default     = 5
}

variable "node_instance_type" {
  description = "EKS worker instance type"
  type        = string
  default     = "t3.medium"
}

variable "enable_rds" {
  description = "Enable RDS database"
  type        = bool
  default     = false
}

variable "enable_elasticache" {
  description = "Enable ElastiCache Redis"
  type        = bool
  default     = true
}

variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "rds_manage_master_user_password" {
  description = "Whether AWS Secrets Manager should manage the RDS master user password."
  type        = bool
  default     = true
}

variable "rds_storage_encrypted" {
  description = "Whether to encrypt RDS storage."
  type        = bool
  default     = true
}

variable "rds_backup_retention_period" {
  description = "Number of days to retain RDS automated backups."
  type        = number
  default     = 7
}

variable "rds_skip_final_snapshot" {
  description = "Whether to skip a final snapshot when deleting RDS."
  type        = bool
  default     = false
}

variable "rds_final_snapshot_identifier" {
  description = "Final snapshot identifier to use when deleting RDS with final snapshots enabled."
  type        = string
  default     = null
}

variable "rds_deletion_protection" {
  description = "Whether deletion protection is enabled for RDS."
  type        = bool
  default     = true
}

variable "rds_apply_immediately" {
  description = "Whether RDS modifications are applied immediately."
  type        = bool
  default     = false
}

variable "secret_name" {
  description = "AWS Secrets Manager secret name for environment values"
  type        = string
  default     = "microservices/dev/app-config"
}

variable "enable_argocd_loadbalancer" {
  description = "Expose ArgoCD UI via AWS LoadBalancer"
  type        = bool
  default     = true
}

variable "argocd_allowed_cidrs" {
  description = "Allowed CIDR blocks to access ArgoCD UI (e.g. ['203.0.113.50/32'] or ['0.0.0.0/0'])"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "argocd_gitops_repo_url" {
  description = "GitOps repository URL that ArgoCD should bootstrap and sync"
  type        = string
  default     = "https://github.com/kumarisback/gitops.git"
}

variable "argocd_gitops_repo_revision" {
  description = "Branch or revision ArgoCD should sync from"
  type        = string
  default     = "HEAD"
}

variable "argocd_gitops_repo_path" {
  description = "Path inside the GitOps repository for the ArgoCD root application"
  type        = string
  default     = "bootstrap/projects"
}

variable "eks_admin_users" {
  description = "List of IAM User ARNs to grant admin access to EKS"
  type        = list(string)
  default     = []
}
