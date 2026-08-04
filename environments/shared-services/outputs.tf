output "vpc_id" {
  value = module.networking.vpc_id
}

output "jenkins_public_ip" {
  value = module.jenkins.public_ip
}

output "jenkins_url" {
  value = "http://${module.jenkins.public_ip}:8080"
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}
