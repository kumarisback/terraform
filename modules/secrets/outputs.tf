output "secret_name" {
  description = "Name of the application secrets"
  value       = var.secret_name
}

output "secret_arn" {
  description = "ARN of the application secrets (if available)"
  value       = local.secret_arn
}

output "mongo_uri" {
  description = "MongoDB connection string from secret"
  value       = lookup(local.secret_values, "MONGO_URI", "")
  sensitive   = true
}

output "jwt_secret" {
  description = "JWT secret from secret"
  value       = lookup(local.secret_values, "JWT_SECRET", "")
  sensitive   = true
}

output "redis_host" {
  description = "Redis host from secret"
  value       = lookup(local.secret_values, "REDIS_HOST", "")
  sensitive   = true
}

output "redis_port" {
  description = "Redis port from secret"
  value       = lookup(local.secret_values, "REDIS_PORT", "")
  sensitive   = true
}
