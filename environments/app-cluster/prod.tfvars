aws_region                = "us-east-1"
project_name              = "microservices"
environment               = "prod"
vpc_cidr                  = "10.30.0.0/16"
public_subnet_cidrs       = ["10.30.1.0/24", "10.30.2.0/24"]
private_app_subnet_cidrs  = ["10.30.11.0/24", "10.30.12.0/24"]
private_data_subnet_cidrs = ["10.30.21.0/24", "10.30.22.0/24"]
enable_nat_gateway        = true
single_nat_gateway        = false # one NAT gateway per AZ for prod HA

eks_endpoint_public_access = false
eks_public_access_cidrs    = []

node_desired_capacity = 2
node_min_capacity     = 2
node_max_capacity     = 6
node_instance_type    = "t3.medium"

enable_rds         = false
enable_elasticache = true
redis_node_type    = "cache.t3.small"
secret_name        = "microservices/prod/app-config"
eks_admin_users    = []

# ArgoCD UI: no public LoadBalancer — access it via `kubectl port-forward`
# instead (see README.md).
enable_argocd_loadbalancer = false
argocd_allowed_cidrs       = []

argocd_gitops_repo_url      = "https://github.com/kumarisback/gitops.git"
argocd_gitops_repo_revision = "HEAD"
argocd_gitops_repo_path     = "bootstrap/projects"
