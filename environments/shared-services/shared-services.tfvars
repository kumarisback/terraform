aws_region            = "us-east-1"
project_name          = "microservices"
environment           = "shared-services"
jenkins_instance_type = "t3.medium"

# Jenkins has no public IP and no open inbound port by default — access it
# via `aws ssm start-session` (see README.md). Only set this to a VPN/office
# CIDR if you specifically want a direct network path from inside the VPC.
jenkins_allowed_cidrs = []
ecr_repositories      = ["user-service", "order-service", "frontend"]
