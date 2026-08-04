variable "name" {
  description = "Base name for secrets resources"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "redis_endpoint" {
  description = "Redis endpoint address"
  type        = string
  default     = ""
}

variable "mongo_uri" {
  description = "MongoDB Atlas connection string"
  type        = string
  default     = "mongodb+srv://username:password@cluster.mongodb.net/db"
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT secret key"
  type        = string
  default     = "change-this-in-production"
  sensitive   = true
}
