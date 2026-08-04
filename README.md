# Terraform Infrastructure Repository

This repository now follows a production-oriented layout with reusable modules and environment-specific execution directories.

## Structure

```text
terraform/
├── modules/
│   ├── networking/           # VPC, subnets, IGW, NAT, routing
│   ├── eks/                  # EKS, IRSA, node groups
│   ├── database/             # RDS and ElastiCache
│   ├── ecr/                  # ECR repositories
│   ├── secrets/              # Secrets Manager integration
│   └── jenkins/              # Jenkins EC2 resources
│
└── environments/
    ├── dev/
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── terraform.tfvars
    │   └── backend.hcl
    │
    ├── staging/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── backend.hcl
    │
    └── prod/
        ├── main.tf
        ├── variables.tf
        └── backend.hcl
```

## Current status

- Networking and Jenkins modules are implemented.
- Dev, staging, and prod environment directories are present.
- Legacy root-level Terraform files remain temporarily for migration and can be phased out gradually.

## Usage

From the development environment folder:

```bash
cd environments/dev
terraform init -backend=false
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

## Next improvements

- Add remote state storage with S3 and DynamoDB
- Implement the remaining modules for EKS, database, ECR, and secrets
- Add Jenkins pipeline validation and deployment stages
