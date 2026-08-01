# Local list of microservices (user-service, order-service, and frontend)
locals {
  ecr_repositories = [
    "user-service",
    "order-service",
    "myapp-frontend"
  ]
}

# 1. ECR Repositories
resource "aws_ecr_repository" "repos" {
  for_each             = toset(local.ecr_repositories)
  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = each.value
  }
}

# 2. Lifecycle Policy to clean up untagged images older than 14 days
resource "aws_ecr_lifecycle_policy" "cleanup_policy" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images, remove untagged"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# 3. Useful Outputs for Docker Push Commands
output "ecr_repository_urls" {
  description = "URLs of the created ECR Repositories"
  value       = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}