locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.name
  }
}

resource "aws_secretsmanager_secret" "app_secrets" {
  name                    = "${var.name}/${var.environment}/app-config"
  description             = "Application secrets for ${var.name} ${var.environment}"
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    Name = "${var.name}-${var.environment}-app-secrets"
  })
}

resource "aws_secretsmanager_secret_version" "app_secrets_val" {
  secret_id = aws_secretsmanager_secret.app_secrets.id

  secret_string = jsonencode({
    MONGO_URI  = var.mongo_uri
    REDIS_HOST = var.redis_endpoint
    REDIS_PORT = "6379"
    JWT_SECRET = var.jwt_secret
  })
}
