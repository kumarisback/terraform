module "networking" {
  source = "../../../modules/networking"

  name                      = var.project_name
  environment               = var.environment
  cidr_block                = var.vpc_cidr
  public_subnet_cidrs       = var.public_subnet_cidrs
  private_app_subnet_cidrs  = var.private_app_subnet_cidrs
  private_data_subnet_cidrs = var.private_data_subnet_cidrs
  enable_nat_gateway        = var.enable_nat_gateway
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