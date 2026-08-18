data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------
# Peering to the shared-services VPC (Jenkins)
#
# Jenkins lives in its own VPC with no route to any app-cluster VPC, so it
# has no way to reach a private-only EKS API endpoint (staging/prod set
# eks_endpoint_public_access = false). This peers this environment's VPC to
# shared-services' so Jenkins can reach the cluster over private networking
# regardless of public endpoint access.
#
# Requires shared-services to already be applied (its state must exist)
# before this environment's first apply — which matches the documented
# bootstrap order (shared-services/Jenkins is stood up once, before any
# app-cluster environment).
# ---------------------------------------------------------

data "terraform_remote_state" "shared_services" {
  count   = var.peer_with_shared_services ? 1 : 0
  backend = "s3"
  config = {
    bucket = var.shared_services_state_bucket
    key    = var.shared_services_state_key
    region = var.aws_region
  }
}

resource "aws_vpc_peering_connection" "shared_services" {
  count       = var.peer_with_shared_services ? 1 : 0
  vpc_id      = module.networking.vpc_id
  peer_vpc_id = data.terraform_remote_state.shared_services[0].outputs.vpc_id
  auto_accept = true # same account + region, so the requester can self-accept

  tags = {
    Name        = "${var.project_name}-${var.environment}-to-shared-services"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Peering alone does NOT extend DNS resolution across the connection — by
# default a peered VPC's resolver won't resolve records in the other VPC's
# private hosted zones, which includes the one EKS auto-creates for the
# cluster's private API endpoint. Without this, Jenkins has a working network
# path to the cluster's ENIs but can't resolve the endpoint hostname to the
# right address, which surfaces as a connection timeout, not a DNS error.
resource "aws_vpc_peering_connection_options" "shared_services" {
  count                     = var.peer_with_shared_services ? 1 : 0
  vpc_peering_connection_id = aws_vpc_peering_connection.shared_services[0].id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }

  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

# Route from this environment's private subnets (where the EKS API's ENIs
# and worker nodes live) back to Jenkins in shared-services.
# Route from ALL of this environment's private subnets back to Jenkins in shared-services
resource "aws_route" "to_shared_services" {
  count                     = var.peer_with_shared_services ? length(module.networking.private_route_table_ids) : 0
  route_table_id            = module.networking.private_route_table_ids[count.index]
  destination_cidr_block    = data.terraform_remote_state.shared_services[0].outputs.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.shared_services[0].id
}

# Route from shared-services' private subnet (where Jenkins runs — it has no
# public IP) to this environment. Owned by this state even though the route
# table itself belongs to shared-services' state — Terraform tracks the
# aws_route resource independently of the route table it's attached to, so
# this is safe as long as shared-services' route table itself isn't replaced.
resource "aws_route" "from_shared_services" {
  count                     = var.peer_with_shared_services ? 1 : 0
  route_table_id            = data.terraform_remote_state.shared_services[0].outputs.private_route_table_id
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.shared_services[0].id
}

module "networking" {
  source = "../../../modules/networking"

  name                      = var.project_name
  environment               = var.environment
  cidr_block                = var.vpc_cidr
  public_subnet_cidrs       = var.public_subnet_cidrs
  private_app_subnet_cidrs  = var.private_app_subnet_cidrs
  private_data_subnet_cidrs = var.private_data_subnet_cidrs
  enable_nat_gateway        = var.enable_nat_gateway
  single_nat_gateway        = var.single_nat_gateway

  # Required for the AWS Load Balancer Controller's subnet auto-discovery
  # (used by gitops/apps/base/ingress.yaml) — without these tags it fails
  # with "unable to resolve at least one subnet".
  public_subnet_tags = {
    "kubernetes.io/role/elb"                                                   = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-eks-cluster" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                                          = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-eks-cluster" = "shared"
  }
}

module "eks" {
  source = "../../../modules/eks"

  name                   = var.project_name
  environment            = var.environment
  vpc_id                 = module.networking.vpc_id
  private_subnet_ids     = module.networking.private_app_subnet_ids
  cluster_version        = var.cluster_version
  endpoint_public_access = var.eks_endpoint_public_access
  public_access_cidrs    = var.eks_public_access_cidrs
  node_desired_capacity  = var.node_desired_capacity
  node_min_capacity      = var.node_min_capacity
  node_max_capacity      = var.node_max_capacity
  node_instance_type     = var.node_instance_type
  admin_users            = var.eks_admin_users
  viewer_users           = var.eks_viewer_users
  group_mapped_users     = var.eks_group_mapped_users
  private_access_cidrs   = var.peer_with_shared_services ? data.terraform_remote_state.shared_services[*].outputs.vpc_cidr_block : []

  irsa_roles = {
    external_secrets = {
      namespace       = "kube-system"
      service_account = "external-secrets-sa"
      inline_policy_json = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect   = "Allow"
            Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
            Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/*"
          }
        ]
      })
    }

    aws_lb_controller = {
      namespace          = "kube-system"
      service_account    = "aws-load-balancer-controller"
      inline_policy_json = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
    }
  }
}

module "database" {
  source = "../../../modules/database"

  name                            = var.project_name
  environment                     = var.environment
  vpc_id                          = module.networking.vpc_id
  vpc_cidr                        = var.vpc_cidr
  private_data_subnet_ids         = module.networking.private_data_subnet_ids
  enable_rds                      = var.enable_rds
  enable_elasticache              = var.enable_elasticache
  redis_node_type                 = var.redis_node_type
  rds_manage_master_user_password = var.rds_manage_master_user_password
  rds_storage_encrypted           = var.rds_storage_encrypted
  rds_backup_retention_period     = var.rds_backup_retention_period
  rds_skip_final_snapshot         = var.rds_skip_final_snapshot
  rds_final_snapshot_identifier   = var.rds_final_snapshot_identifier
  rds_deletion_protection         = var.rds_deletion_protection
  rds_apply_immediately           = var.rds_apply_immediately
}

module "secrets" {
  source        = "../../../modules/secrets"
  secret_name   = var.secret_name
  manage_secret = true
  secret_values = {
    REDIS_HOST = module.database.redis_endpoint
    REDIS_PORT = "6379"
  }
}

resource "aws_ssm_parameter" "redis_endpoint" {
  count = var.enable_elasticache ? 1 : 0

  name  = "/${var.environment}/redis/endpoint"
  type  = "String"
  value = module.database.redis_endpoint
}

resource "aws_ssm_parameter" "rds_endpoint" {
  count = var.enable_rds ? 1 : 0

  name  = "/${var.environment}/rds/endpoint"
  type  = "String"
  value = module.database.rds_endpoint
}
