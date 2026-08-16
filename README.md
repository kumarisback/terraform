# Terraform Infrastructure Setup Guide

Welcome! This repository is your starting point for creating the cloud infrastructure (AWS EKS, VPC, RDS) and automatically setting up our GitOps pipeline (ArgoCD).

**Goal**: Follow these instructions to spin up a completely fresh environment (like `dev` or `prod`) from scratch. By the end of this guide, your cluster will be running, and ArgoCD will be automatically installed and waiting for application deployments.

## Contents

- [Quick reference: URLs & public/private access](#quick-reference-urls--publicprivate-access) — **start here if you just need a URL or want to flip something public/private**
- [Prerequisites](#prerequisites)
- [Step 1: Configure Your Environment](#step-1-configure-your-environment)
- [Step 2: Deploy the Infrastructure (Manual Approach)](#step-2-deploy-the-infrastructure-manual-approach)
- [Step 3: What Just Happened?](#step-3-what-just-happened)
- [Step 4: Accessing Jenkins, ArgoCD, and Deployed Services (detailed)](#step-4-accessing-jenkins-argocd-and-deployed-services)
- [Step 5: Granting Roles/Policies, and Making Things Public](#step-5-granting-rolespolicies-and-making-things-public)
- [(Alternative) Deploying via Jenkins](#alternative-deploying-via-jenkins)

---

## Quick reference: URLs & public/private access

Everything here is explained in full in [Step 4](#step-4-accessing-jenkins-argocd-and-deployed-services)
and [Step 5](#step-5-granting-rolespolicies-and-making-things-public) — this table is just
the fast path so you don't have to read either.

<a id="qr-jenkins"></a>

| | Jenkins UI | ArgoCD UI | `frontend` app |
|---|---|---|---|
| **Default** | Private (no public IP) | Private (`ClusterIP`, no LoadBalancer) | **Public** (`type: LoadBalancer`) |
| **Get the URL / connect** | [SSM port-forward ↓](#jenkins-cicd) | [kubectl port-forward ↓](#argocd-gitops-ui) | [kubectl get svc ↓](#public-facing-application-services-eg-frontend) |
| **Make it public** | [Set `jenkins_allowed_cidrs` ↓](#make-jenkins-reachable-from-the-network-again) | [Set `enable_argocd_loadbalancer` ↓](#make-argocds-ui-public-again) | Already public by default |
| **Make it private** | Set `jenkins_allowed_cidrs = []`, re-apply `shared-services` | Set `enable_argocd_loadbalancer = false`, re-apply Layer 2 | Change the Service's `type:` to `ClusterIP` in `gitops/apps/base/frontend/service.yaml` |

**The one-liners**, once you have the instance ID / are `kubectl`-connected:

```bash
# Jenkins UI → http://localhost:8080
aws ssm start-session \
  --target "$(terraform output -raw jenkins_instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'

# ArgoCD UI → https://localhost:8080  (dev only — see Step 4 for staging/prod)
aws eks update-kubeconfig --name microservices-dev-eks-cluster --region us-east-1
kubectl port-forward svc/argocd-server -n argocd 8080:443

# frontend app's public URL
kubectl get svc frontend -n development \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

`terraform output -raw jenkins_instance_id` is run from `infrastructure/shared-services`
after that layer has been applied.

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
3. This repo's Terraform is split into two layers per environment — `01-infra` (VPC/EKS/DB) and `02-services` (ArgoCD/platform add-ons) — each with its own state file and its own backend config:
   - `environments/app-cluster/dev-infra-backend.hcl` — Layer 1's state
   - `environments/app-cluster/dev-services-backend.hcl` — Layer 2's state

   Make sure the `bucket` in both exists in your AWS account (they use S3-native locking, so no separate DynamoDB table is needed).
4. Before deploying `dev` for the first time, `infrastructure/shared-services` (Jenkins, ECR) must already be applied — Layer 1 peers its VPC to shared-services, so shared-services has to exist first. See `environments/shared-services/`.

---

## Step 2: Deploy the Infrastructure (Manual Approach)

If you are not using Jenkins, follow these steps in your terminal. Each layer is applied
from its own directory, in order.

**Layer 1 — Infrastructure (VPC, EKS, RDS):**
```bash
cd infrastructure/app-cluster/01-infra

terraform init -backend-config=../../../environments/app-cluster/dev-infra-backend.hcl
terraform plan -var-file=../../../environments/app-cluster/dev.tfvars -out=tfplan
terraform apply tfplan
```
*(This step can take 15-20 minutes as it provisions the EKS cluster and databases.)*

**Layer 2 — Services (ArgoCD, External Secrets, AWS Load Balancer Controller):**
```bash
cd ../02-services

# Layer 2's helm/kubernetes providers need a live cluster + kubeconfig, so refresh it first
aws eks update-kubeconfig --name microservices-dev-eks-cluster --region us-east-1

terraform init -backend-config=../../../environments/app-cluster/dev-services-backend.hcl
terraform plan -var-file=../../../environments/app-cluster/dev.tfvars -out=tfplan
terraform apply tfplan
```

For `staging`/`prod`, swap `dev` for the environment name in every path/flag above.

---

## Step 3: What Just Happened?

When both layers finish successfully:
1. Your AWS EKS Cluster is up and running.
2. Your AWS RDS Database (if enabled) is created.
3. The database connection details are securely saved into **AWS Systems Manager (SSM)**.
4. **ArgoCD is automatically installed** via Helm.
5. Terraform creates an ArgoCD root Application that points at the GitOps repository: `https://github.com/kumarisback/gitops.git`.
6. ArgoCD automatically syncs that GitOps repo and deploys the applications in `bootstrap/projects`.

You do NOT need to run any `kubectl` commands to deploy your apps. Jump over to the **GitOps Repository README** to see how to deploy and update your services.

**Now — where's everything?** See the [Quick reference table](#quick-reference-urls--publicprivate-access) above, or the detailed walkthrough in [Step 4](#step-4-accessing-jenkins-argocd-and-deployed-services) below.

---

## Step 4: Accessing Jenkins, ArgoCD, and Deployed Services

Neither Jenkins nor ArgoCD is exposed to the internet. Here's how to reach
each of them, and how to find a deployed application's URL, after `apply`
has finished. (Looking for the short version? See the
[Quick reference table](#quick-reference-urls--publicprivate-access) at the top of this file.)

<a id="jenkins-cicd"></a>
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

<a id="make-jenkins-reachable-from-the-network-again"></a>
**Making it public/reachable directly** (instead of via SSM): set
`jenkins_allowed_cidrs` in `environments/shared-services/shared-services.tfvars` to your
IP/VPN CIDR and re-apply. That opens SSH (22) and the UI (8080) on Jenkins' security group
from those addresses only. Jenkins still has no public IP, so this only works from inside
the VPC or over a VPN into it — it does not make Jenkins internet-reachable. To go back to
private-only, set it back to `[]` and re-apply.

<a id="argocd-gitops-ui"></a>
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

<a id="make-argocds-ui-public-again"></a>
**Making it public** (a real LoadBalancer instead of port-forwarding): set, per environment,
in `environments/app-cluster/<env>.tfvars`:
```hcl
enable_argocd_loadbalancer = true
argocd_allowed_cidrs       = ["<your-ip>/32"] # never 0.0.0.0/0 beyond a quick throwaway test
```
Re-apply Layer 2 (`02-services`). To go back to private-only, set
`enable_argocd_loadbalancer = false` and re-apply again.

<a id="public-facing-application-services-eg-frontend"></a>
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

This one is public **by default** — to make it private, change `spec.type` from
`LoadBalancer` to `ClusterIP` in `gitops/apps/base/frontend/service.yaml` and push; ArgoCD
will sync the change (and Kubernetes will tear down the AWS load balancer).

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

See the [Quick reference table](#quick-reference-urls--publicprivate-access) at the top, or
the [full explanation above](#jenkins-cicd).

### Make ArgoCD's UI public again

See the [Quick reference table](#quick-reference-urls--publicprivate-access) at the top, or
the [full explanation above](#argocd-gitops-ui).

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
