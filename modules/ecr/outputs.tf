output "repository_urls" {
  description = "URLs of the created ECR repositories"
  value       = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}

output "repository_arns" {
  description = "ARNs of the created ECR repositories"
  value       = { for k, v in aws_ecr_repository.repos : k => v.arn }
}
