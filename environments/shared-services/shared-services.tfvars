aws_region            = "us-east-1"
project_name          = "microservices"
environment           = "shared-services"
jenkins_instance_type = "t3.medium"
jenkins_allowed_cidrs = ["0.0.0.0/0"]
ecr_repositories      = ["user-service", "order-service", "frontend"]
