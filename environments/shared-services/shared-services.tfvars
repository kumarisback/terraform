aws_region            = "us-east-1"
project_name          = "microservices"
environment           = "shared-services"
jenkins_instance_type = "t3.medium"

# Learning only: public access lets you open the Jenkins dashboard from your internet.
# Before real use, replace this with your public IP as /32 or a VPN CIDR.
jenkins_allowed_cidrs = ["0.0.0.0/0"]
ecr_repositories      = ["user-service", "order-service", "frontend"]
