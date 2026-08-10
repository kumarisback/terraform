# Terraform Infrastructure Setup Guide

Welcome! This repository is your starting point for creating the cloud infrastructure (AWS EKS, VPC, RDS) and automatically setting up our GitOps pipeline (ArgoCD).

**Goal**: Follow these instructions to spin up a completely fresh environment (like `dev` or `prod`) from scratch. By the end of this guide, your cluster will be running, and ArgoCD will be automatically installed and waiting for application deployments.

---

## Prerequisites
Before you begin, ensure you have:
1. **AWS CLI** installed and authenticated (`aws configure`) with Administrator permissions.
2. **Terraform** installed (v1.2+).
3. **kubectl** installed (to interact with the cluster later).

---

## Step 1: Configure Your Environment

All configuration happens in the `environments/app-cluster/` folder.
Let's say you want to deploy the `dev` environment.

1. Open `environments/app-cluster/dev.tfvars`. This file controls the shape of your infrastructure (e.g., how many nodes, VPC size, etc.).
2. Update any variables if needed. By default, it is configured for a standard microservices deployment.
3. Open `environments/app-cluster/dev-backend.hcl`. This defines where Terraform saves its state. Make sure the `bucket` and `dynamodb_table` exist in your AWS account to safely store state.

---

## Step 2: Deploy the Infrastructure (Manual Approach)

If you are not using Jenkins, follow these steps in your terminal:

1. Navigate to the root infrastructure module:
   ```bash
   cd infrastructure/app-cluster
   ```

2. Initialize Terraform for your specific environment:
   ```bash
   terraform init -backend-config=../../environments/app-cluster/dev-backend.hcl
   ```

3. Preview the changes (Optional but recommended):
   ```bash
   terraform plan -var-file=../../environments/app-cluster/dev.tfvars -out=tfplan
   ```

4. Apply the changes to create the cloud resources:
   ```bash
   terraform apply tfplan
   ```
   *(Note: This step can take 15-20 minutes as it provisions the EKS cluster and databases).*

---

## Step 3: What Just Happened?

When the `terraform apply` finishes successfully:
1. Your AWS EKS Cluster is up and running.
2. Your AWS RDS Database (if enabled) is created.
3. The database connection details are securely saved into **AWS Systems Manager (SSM)**.
4. **ArgoCD is automatically installed** via Helm.
5. Terraform creates an ArgoCD root Application that points at the GitOps repository: `https://github.com/kumarisback/gitops.git`.
6. ArgoCD automatically syncs that GitOps repo and deploys the applications in `bootstrap/projects`.

You do NOT need to run any `kubectl` commands to deploy your apps. Jump over to the **GitOps Repository README** to see how to deploy and update your services.

---

## (Alternative) Deploying via Jenkins

If you prefer CI/CD automation:
1. Open your Jenkins dashboard and point a Pipeline job to this repository.
2. Run the build with Parameters.
3. Select `ENVIRONMENT` = `dev` (or `staging`, `prod`).
4. Jenkins will run security scans (`checkov`) and execute the terraform commands above automatically.
