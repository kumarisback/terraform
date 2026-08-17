aws_region                = "us-east-1"
project_name              = "microservices"
environment               = "dev"
vpc_cidr                  = "10.10.0.0/16"
public_subnet_cidrs       = ["10.10.1.0/24", "10.10.2.0/24"]
private_app_subnet_cidrs  = ["10.10.11.0/24", "10.10.12.0/24"]
private_data_subnet_cidrs = ["10.10.21.0/24", "10.10.22.0/24"]
enable_nat_gateway        = true

# EKS API access.
# Best practice: set this to your public IP as /32 or a VPN CIDR.
eks_endpoint_public_access = false
eks_public_access_cidrs    = []

# ArgoCD UI: no public LoadBalancer — access it via `kubectl port-forward`
# instead (see README.md).
enable_argocd_loadbalancer = false
argocd_allowed_cidrs       = []

# Deploy only dev's own app set (+ shared platform components) into this
# cluster — NOT bootstrap/projects, which would also deploy staging's and
# prod's full app sets into this same cluster.
argocd_gitops_repo_path = "bootstrap/envs/dev"

# EKS Access Configuration
eks_admin_users = ["arn:aws:iam::602367507570:user/terraform"]
