aws_region                = "us-east-1"
project_name              = "microservices"
environment               = "dev"
vpc_cidr                  = "10.10.0.0/16"
public_subnet_cidrs       = ["10.10.1.0/24", "10.10.2.0/24"]
private_app_subnet_cidrs  = ["10.10.11.0/24", "10.10.12.0/24"]
private_data_subnet_cidrs = ["10.10.21.0/24", "10.10.22.0/24"]
enable_nat_gateway        = true

# ArgoCD UI Exposure Configuration
enable_argocd_loadbalancer = true
# To restrict access to your IP address only, uncomment and update the line below:
# argocd_allowed_cidrs     = ["203.0.113.50/32"]
argocd_allowed_cidrs = ["0.0.0.0/0"]

# EKS Access Configuration
eks_admin_users = ["arn:aws:iam::602367507570:user/terraform"]

