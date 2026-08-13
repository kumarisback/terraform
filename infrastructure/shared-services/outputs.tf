output "vpc_id" {
  description = "ID of the shared services VPC"
  value       = module.networking.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the shared services VPC"
  value       = module.networking.vpc_cidr_block
}

output "public_route_table_id" {
  description = "Route table ID for the shared services VPC's public subnets (where Jenkins runs)"
  value       = module.networking.public_route_table_id
}

output "jenkins_public_ip" {
  description = "Public IP address of Jenkins"
  value       = module.jenkins.public_ip
}

output "jenkins_url" {
  description = "Jenkins URL"
  value       = "http://${module.jenkins.public_ip}:8080"
}

output "ecr_repository_urls" {
  description = "ECR repository URLs"
  value       = module.ecr.repository_urls
}

output "public_subnet_ids" {
  description = "Public subnet IDs of the shared VPC"
  value       = module.networking.public_subnet_ids
}

output "private_app_subnet_ids" {
  description = "Private application subnet IDs"
  value       = module.networking.private_app_subnet_ids
}

output "private_data_subnet_ids" {
  description = "Private data subnet IDs"
  value       = module.networking.private_data_subnet_ids
}