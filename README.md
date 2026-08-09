# Terraform Infrastructure Repository

This repository provisions the foundational AWS cloud infrastructure (VPC, EKS, RDS) and securely bootstraps GitOps (ArgoCD) to achieve a fully automated deployment pipeline. It follows a DRY (Don't Repeat Yourself) architecture.

## Architecture Structure

```text
terraform/
├── infrastructure/
│   ├── app-cluster/          # Unified root module for dev, staging, prod clusters
│   └── shared-services/      # Root module for shared tools (Jenkins, ECR)
│
├── environments/
│   ├── app-cluster/
│   │   ├── dev.tfvars        # Variables for the Dev environment
│   │   ├── prod.tfvars       # Variables for the Prod environment
│   │   └── ...
│   └── shared-services/
│
└── modules/                  # Reusable Terraform modules (eks, networking, database, etc.)
```

## How It Works (The Automation Bridge)

When this Terraform code runs, it:
1. Creates the VPC, Subnets, and EKS Cluster.
2. Creates the RDS Database (if enabled) and pushes the endpoint to **AWS Systems Manager (SSM) Parameter Store**.
3. Uses the Terraform Helm provider to **automatically install ArgoCD** into the EKS cluster.
4. Tells ArgoCD to track your GitOps repository, triggering the deployment of your applications.

## How to Deploy (End-to-End)

### Option 1: Via Jenkins (Recommended)
This repository contains a `Jenkinsfile`.
1. Point your Jenkins pipeline to this repository.
2. Trigger a build and select your target `ENVIRONMENT` parameter (e.g., `dev`).
3. Jenkins will run a `checkov` security scan and automatically apply the infrastructure.

### Option 2: Manual Deployment via CLI
If you want to deploy manually from your machine:

1. **Authenticate with AWS**: Ensure your AWS CLI is authenticated and has administrative permissions.
2. **Initialize the Environment**:
   ```bash
   cd infrastructure/app-cluster
   terraform init -backend-config=../../environments/app-cluster/dev-backend.hcl
   ```
3. **Plan the Changes**:
   ```bash
   terraform plan -var-file=../../environments/app-cluster/dev.tfvars -out=tfplan
   ```
4. **Apply the Infrastructure**:
   ```bash
   terraform apply tfplan
   ```

Once Terraform finishes, ArgoCD is instantly installed and will automatically connect to your GitOps repository to deploy your microservices!
