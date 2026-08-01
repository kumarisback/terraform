# 1. AWS Secrets Manager Secret Container
resource "aws_secretsmanager_secret" "app_secrets" {
  name                    = "microservices/app-config"
  description             = "App secrets (MongoDB Atlas, Redis, JWT) for microservices"
  recovery_window_in_days = 0 # Forces immediate deletion upon destroy (ideal for local dev teardowns)

  tags = {
    Name = "microservices-app-secrets"
  }
}

# 2. Secret Payload (JSON Key-Value Pair)
resource "aws_secretsmanager_secret_version" "app_secrets_val" {
  secret_id = aws_secretsmanager_secret.app_secrets.id

  secret_string = jsonencode({
    # Replace with your actual MongoDB Atlas connection string when deploying apps:
    MONGO_URI  = "mongodb+srv://<username>:<password>@cluster0.mongodb.net/microservices_db?retryWrites=true&w=majority"
    REDIS_HOST = aws_elasticache_cluster.redis.cache_nodes[0].address
    REDIS_PORT = "6379"
    JWT_SECRET = "supersecretjwtkey123_change_in_prod"
  })
}

# 3. Outputs for Helm / External Secrets Operator
output "secrets_manager_arn" {
  description = "ARN of the application secrets stored in Secrets Manager"
  value       = aws_secretsmanager_secret.app_secrets.arn
}

output "secrets_manager_name" {
  description = "Name of the secret resource for ExternalSecrets ClusterSecretStore"
  value       = aws_secretsmanager_secret.app_secrets.name
}