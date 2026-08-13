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

## Step 5: Granting Roles/Policies, and Making Things Public

This repo is built so a fork can add a new service, grant it exactly the
AWS access it needs, and expose it publicly — all through config changes,
no code changes required for the common cases.

### Grant a human admin access to an EKS cluster

Add their IAM user/role ARN to `eks_admin_users` in the relevant
`environments/app-cluster/<env>.tfvars`, then re-apply Layer 1:
```hcl
eks_admin_users = ["arn:aws:iam::<account-id>:user/<name>"]
```

### Give an in-cluster controller its own AWS permissions (IRSA)

Don't widen the node role — give the controller its own scoped IAM role
instead. Add an entry to the `irsa_roles` map passed to `module "eks"` in
`infrastructure/app-cluster/01-infra/main.tf` (the `external_secrets` and
`aws_lb_controller` entries already there are examples to copy):
```hcl
irsa_roles = {
  my_controller = {
    namespace       = "kube-system"          # or wherever it runs
    service_account = "my-controller-sa"     # must match the chart's SA name
    policy_arns     = ["arn:aws:iam::aws:policy/SomeManagedPolicy"] # AWS managed policy, or:
    inline_policy_json = jsonencode({         # a custom, tightly scoped policy
      Version = "2012-10-17"
      Statement = [{ Effect = "Allow", Action = ["..."], Resource = "..." }]
    })
  }
}
```
Re-apply Layer 1, then read the resulting ARN in Layer 2 via
`data.terraform_remote_state.infra.outputs.irsa_role_arns["my_controller"]`
and annotate that Helm chart's ServiceAccount with
`eks.amazonaws.com/role-arn` — exactly as `helm_release.external_secrets`
and `helm_release.aws_lb_controller` already do in
`infrastructure/app-cluster/02-services/main.tf`.

### Give Jenkins additional AWS permissions

Jenkins' policy (`modules/jenkins/main.tf`) is broad-but-scoped: full CRUD
within EC2/EKS/RDS/ElastiCache, but IAM/Secrets Manager/SSM are all
restricted to this project's name prefix. If a new service needs Jenkins to
touch another AWS service, add a new statement to
`aws_iam_role_policy.jenkins_terraform_provisioner`, scoped to a specific
resource ARN pattern — never `Resource = "*"` for anything beyond the
EC2/EKS/RDS/ElastiCache statement that's already there for a reason (see
the comment above it).

For access to resources outside this account/project entirely, prefer
`jenkins_terraform_deploy_role_arns` in `shared-services.tfvars` — Jenkins
assumes that role via STS instead of holding the permissions itself.

### Make Jenkins reachable from the network again

Set `jenkins_allowed_cidrs` in
`environments/shared-services/shared-services.tfvars` to your IP/VPN CIDR
and re-apply. This opens SSH (22) and the UI (8080) on Jenkins' security
group from those addresses only — Jenkins still has no public IP, so this
only helps from inside the VPC or over a VPN into it. For access from
anywhere, use the SSM flow in Step 4 instead of widening this.

### Make ArgoCD's UI public again

Set, per environment, in `environments/app-cluster/<env>.tfvars`:
```hcl
enable_argocd_loadbalancer = true
argocd_allowed_cidrs       = ["<your-ip>/32"] # never 0.0.0.0/0 beyond a quick throwaway test
```
Re-apply Layer 2 (`02-services`).

### Expose a new microservice publicly

Two options, both already supported end-to-end by this repo:

- **Simple, no host/path routing needed**: set the Service's
  `spec.type: LoadBalancer` in `gitops/apps/base/<service>/service.yaml` —
  AWS provisions a load balancer automatically (same as `frontend` today).
  No Terraform change needed.
- **Host/path-based routing, TLS, or multiple services behind one ALB**: add
  an `Ingress` instead, annotated for the AWS Load Balancer Controller
  (already installed via Terraform in `02-services`):
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    name: my-service
    annotations:
      kubernetes.io/ingress.class: alb
      alb.ingress.kubernetes.io/scheme: internet-facing
  spec:
    rules:
      - host: my-service.example.com
        http:
          paths:
            - path: /
              pathType: Prefix
              backend:
                service: { name: my-service, port: { number: 80 } }
  ```

### Deploy a brand-new service end-to-end

1. **ECR**: add the repo name to `ecr_repositories` in
   `environments/shared-services/shared-services.tfvars`, re-apply
   shared-services.
2. **Manifests**: copy the pattern in `gitops/apps/base/frontend/` into
   `gitops/apps/base/<service>/`, add it to
   `gitops/apps/base/kustomization.yaml`'s `resources`, and add an
   `images:` entry per environment — see the gitops repo's README,
   "Adding a Brand New Microservice," for the full walkthrough.
3. **AWS permissions, if the service needs any**: give it its own IRSA
   role as described above instead of widening the node role.
4. **Push**: commit to the gitops repo's `main` branch. ArgoCD syncs it
   automatically — no `kubectl apply`, no re-running Terraform, unless the
   service needs new AWS-side resources (ECR repo, IRSA role, etc.).

---

## (Alternative) Deploying via Jenkins

If you prefer CI/CD automation:
1. Open your Jenkins dashboard and point a Pipeline job to this repository.
2. Run the build with Parameters.
3. Select `ENVIRONMENT` = `dev` (or `staging`, `prod`).
4. Jenkins will run security scans (`checkov`) and execute the terraform commands above automatically.
