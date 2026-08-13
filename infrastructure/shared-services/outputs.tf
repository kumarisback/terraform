output "vpc_id" {
  description = "ID of the shared services VPC"
  value       = module.networking.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the shared services VPC"
  value       = module.networking.vpc_cidr_block
}

output "public_route_table_id" {
  description = "Route table ID for the shared services VPC's public subnets"
  value       = module.networking.public_route_table_id
}

output "private_route_table_id" {
  description = "Route table ID for the shared services VPC's private subnets (where Jenkins now runs)"
  value       = module.networking.private_route_table_id
}

output "jenkins_private_ip" {
  description = "Private IP address of Jenkins (reachable via SSM port-forward or from inside the VPC/VPN)"
  value       = module.jenkins.private_ip
}

output "jenkins_instance_id" {
  description = "EC2 instance ID of Jenkins — needed for `aws ssm start-session --target <this>`"
  value       = module.jenkins.instance_id
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