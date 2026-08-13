# Terraform Infrastructure Setup Guide

Welcome! This repository is your starting point for creating the cloud infrastructure (AWS EKS, VPC, RDS) and automatically setting up our GitOps pipeline (ArgoCD).

**Goal**: Follow these instructions to spin up a completely fresh environment (like `dev` or `prod`) from scratch. By the end of this guide, your cluster will be running, and ArgoCD will be automatically installed and waiting for application deployments.

---

## Prerequisites
Before you begin, ensure you have:
1. **AWS CLI** installed and authenticated (`aws configure`) with Administrator permissions.
2. **Terraform** installed (v1.12+).
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

## Step 4: Accessing Jenkins, ArgoCD, and Deployed Services

Neither Jenkins nor ArgoCD is exposed to the internet. Here's how to reach
each of them, and how to find a deployed application's URL, after `apply`
has finished.

### Jenkins (CI/CD)

Jenkins has no public IP and no open inbound port. Connect via AWS Systems
Manager (SSM) instead — it needs no security group rule, only the
`AmazonSSMManagedInstanceCore` permission already attached to Jenkins' IAM
role.

1. Get the instance ID (from `infrastructure/shared-services`, after apply):
   ```bash
   terraform output -raw jenkins_instance_id
   ```
2. Open a shell on Jenkins:
   ```bash
   aws ssm start-session --target <instance-id>
   ```
3. To reach the Jenkins web UI from your browser instead, forward its port
   over the same SSM channel:
   ```bash
   aws ssm start-session \
     --target <instance-id> \
     --document-name AWS-StartPortForwardingSession \
     --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
   ```
   Then open http://localhost:8080.
4. Get the initial admin password (from inside an SSM shell session):
   ```bash
   sudo cat /var/lib/jenkins/secrets/initialAdminPassword
   ```

If you'd rather connect directly over the network (e.g. from a VPN/office
CIDR) instead of SSM, set `jenkins_allowed_cidrs` in
`environments/shared-services/shared-services.tfvars` to that CIDR and
re-apply. Jenkins still has no public IP, so this only works from inside the
VPC or over a VPN into it — it does not make Jenkins internet-reachable.

### ArgoCD (GitOps UI)

ArgoCD's server Service is `ClusterIP` — no public LoadBalancer. Access it
with `kubectl port-forward`.

**Dev** (its EKS API endpoint is public, restricted to the IP in
`eks_public_access_cidrs`):
```bash
aws eks update-kubeconfig --name microservices-dev-eks-cluster --region us-east-1
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
Open https://localhost:8080 (self-signed cert — expect a browser warning).
Username is `admin`; get the initial password with:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

**Staging/prod** (their EKS API endpoints are private-only): your laptop
isn't on that network, so tunnel through Jenkins, which already has a path
to these clusters via the VPC peering this repo sets up between
shared-services and each environment:
```bash
# 1. Shell onto Jenkins
aws ssm start-session --target <jenkins-instance-id>

# 2. On Jenkins, point kubectl at the target cluster and forward ArgoCD
aws eks update-kubeconfig --name microservices-staging-eks-cluster --region us-east-1
kubectl port-forward svc/argocd-server -n argocd 8080:443 --address 0.0.0.0

# 3. From your laptop, open a second SSM tunnel to Jenkins' own port 8080
aws ssm start-session \
  --target <jenkins-instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```
Then open https://localhost:8080 on your laptop.

### Public-facing application services (e.g. `frontend`)

The `frontend` Service (`gitops/apps/base/frontend/service.yaml`) is
`type: LoadBalancer` — Kubernetes creates a real AWS load balancer for it
directly; Terraform doesn't track it. Once ArgoCD has synced it, find its
URL with:
```bash
kubectl get svc frontend -n <development|staging|production> \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```
(or look in the EC2 → Load Balancers console, in the relevant environment's
VPC, for one tagged `elbv2.k8s.aws/cluster`).

### Everything else Terraform created

Run `terraform output` from the relevant layer to list everything it knows
about, or `terraform output -raw <name>` for one value without quotes:

- `infrastructure/shared-services` → `jenkins_instance_id`, `jenkins_private_ip`, `ecr_repository_urls`
- `infrastructure/app-cluster/01-infra` → `cluster_name`, `cluster_endpoint`, `vpc_id`
- `infrastructure/app-cluster/02-services` → `argocd_namespace`, `argocd_server_url` (reports `"ClusterIP (Use kubectl port-forward)"` since the public LoadBalancer is disabled by default)

---

## (Alternative) Deploying via Jenkins

If you prefer CI/CD automation:
1. Open your Jenkins dashboard and point a Pipeline job to this repository.
2. Run the build with Parameters.
3. Select `ENVIRONMENT` = `dev` (or `staging`, `prod`).
4. Jenkins will run security scans (`checkov`) and execute the terraform commands above automatically.
