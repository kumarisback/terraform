# Terraform Repository Review

Review date: 2026-08-11

This review covers the Terraform repo under `/Users/arunkumar/Workspace/terraform`. I checked the reusable modules, environment tfvars/backend files, Jenkins pipeline, and ran lightweight Terraform checks.

## Quick Result

The repo has a good starting structure: separate modules for networking, EKS, database, ECR, Jenkins, and secrets; environment-specific tfvars; provider version constraints; and a CI pipeline with `fmt` and `validate`.

The biggest problems are around security exposure, environment separation, secrets/state handling, and production safety defaults.

## Critical Issues

### 1. EKS API endpoint is open to the internet

Location: `modules/eks/main.tf`, lines 98-100

```hcl
endpoint_public_access  = true
public_access_cidrs     = ["0.0.0.0/0"]
endpoint_private_access = true
```

What is wrong:

Anyone on the internet can reach the Kubernetes API endpoint. Authentication is still required, but this increases attack surface a lot.

Best practice:

Restrict `public_access_cidrs` to your VPN, office IP, or trusted admin IP ranges. For production, prefer private endpoint access and reach the cluster through VPN, Direct Connect, SSM/bastion, or a controlled admin network.

Suggested direction:

```hcl
variable "eks_public_access_cidrs" {
  type    = list(string)
  default = []
}
```

Then pass this variable into the EKS module instead of hardcoding `0.0.0.0/0`.

### 2. Jenkins has AdministratorAccess

Location: `modules/jenkins/main.tf`, lines 35-38

```hcl
resource "aws_iam_role_policy_attachment" "administrator" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
```

What is wrong:

If Jenkins is compromised, the attacker gets full AWS account control. This is the highest-risk issue in the repo.

Best practice:

Use least-privilege IAM. Give Jenkins only the actions it needs for Terraform state, ECR push/pull, EKS deployment, and the specific infrastructure it manages. Ideally Jenkins should assume a deployment role per environment instead of owning broad permanent permissions directly.

Suggested direction:

- Remove `AdministratorAccess`.
- Replace broad `AmazonS3FullAccess` and `AmazonDynamoDBFullAccess` with policies scoped to the exact Terraform state bucket, state key prefix, and lock table.
- Use separate `dev`, `staging`, and `prod` deployment roles.
- Require manual approval or separate credentials for production.

### 3. Jenkins and ArgoCD are exposed to the world by default

Locations:

- `infrastructure/shared-services/variables.tf`, line 69
- `environments/shared-services/shared-services.tfvars`, line 5
- `infrastructure/app-cluster/variables.tf`, lines 103-112
- `environments/app-cluster/dev.tfvars`, lines 11-14

What is wrong:

Jenkins access defaults to `0.0.0.0/0`, and ArgoCD LoadBalancer access also defaults to `0.0.0.0/0`. Jenkins and ArgoCD are sensitive control-plane tools. Public exposure is risky even with login enabled.

Best practice:

Do not expose CI/CD and GitOps admin tools publicly. Restrict access to VPN/admin CIDRs, place them behind an internal load balancer, use SSO, and enforce TLS.

Suggested direction:

- Change defaults to empty lists or trusted CIDRs.
- Fail validation if `prod` uses `0.0.0.0/0`.
- Use internal load balancers where possible.

### 4. Secrets are managed through `local-exec` and AWS CLI

Location: `modules/secrets/main.tf`, lines 16-35

What is wrong:

Terraform shells out to `aws secretsmanager create-secret` / `put-secret-value`. This bypasses normal Terraform resource tracking. It can cause drift, weak lifecycle handling, inconsistent plans, and local machine/CI dependency issues.

Best practice:

Use native Terraform resources:

- `aws_secretsmanager_secret`
- `aws_secretsmanager_secret_version`

Also mark sensitive variables/outputs as sensitive and avoid printing secret JSON in logs.

Suggested direction:

Replace the `null_resource` with provider-managed resources. If the secret may already exist, import it into Terraform state or make ownership explicit with a variable like `create_secret`.

## High Priority Issues

### 5. RDS SSM parameter stores Redis endpoint

Location: `infrastructure/app-cluster/main.tf`, lines 94-98

```hcl
resource "aws_ssm_parameter" "rds_endpoint" {
  name  = "/${var.environment}/rds/endpoint"
  type  = "String"
  value = module.database.redis_endpoint
}
```

What is wrong:

The parameter name says `rds`, but the value is the Redis endpoint. This will confuse apps and operators and can create broken deployments later.

Best practice:

Create separate outputs/parameters for each service:

- `/${var.environment}/redis/endpoint`
- `/${var.environment}/rds/endpoint` only when RDS is enabled

Use conditional creation for RDS parameters when `enable_rds = true`.

### 6. Production and staging configs are empty

Locations:

- `environments/app-cluster/prod.tfvars`
- `environments/app-cluster/prod-backend.hcl`
- `environments/app-cluster/staging-backend.hcl`

What is wrong:

Running prod or staging can silently use defaults from `variables.tf`. For example, `environment` defaults to `dev`, `secret_name` defaults to `microservices/dev/app-config`, and ArgoCD defaults to public exposure.

Best practice:

Every environment should have complete, explicit tfvars and backend config. Production should never depend on development defaults.

Suggested direction:

- Fill all required prod/staging values.
- Remove risky defaults from root variables.
- Use validation rules to ensure `environment` is one of `dev`, `staging`, or `prod`.
- Make backend buckets, state keys, and lock tables unique per environment.

### 7. Shared-services root module has no remote backend

Location: `infrastructure/shared-services/main.tf`, lines 1-10

What is wrong:

`app-cluster` has `backend "s3" {}`, but `shared-services` does not. If applied from a workstation or Jenkins workspace, shared-services state may be local and easy to lose.

Best practice:

Use a remote backend with state locking for every root module.

Suggested direction:

Add:

```hcl
terraform {
  backend "s3" {}
}
```

Then create `environments/shared-services/shared-services-backend.hcl`.

### 8. RDS defaults are unsafe for real environments

Location: `modules/database/main.tf`, lines 125-128 and `modules/database/variables.tf`, lines 78-85

What is wrong:

The RDS module uses:

- `skip_final_snapshot = true`
- `deletion_protection = false`
- `apply_immediately = true`
- default password `ChangeMe123!`

Best practice:

For staging/prod:

- Enable deletion protection.
- Take a final snapshot before deletion.
- Avoid immediate disruptive changes unless intentionally approved.
- Never keep real passwords as defaults in code.
- Prefer Secrets Manager generated passwords or external secret injection.

## Medium Priority Issues

### 9. Security groups are broader than needed

Locations:

- `modules/database/main.tf`, lines 16-30 and 51-57
- `modules/jenkins/main.tf`, lines 51-65

What is wrong:

Database access is allowed from the entire VPC CIDR. Jenkins exposes SSH and UI from the configured CIDR, currently world-open in tfvars.

Best practice:

Prefer security-group-to-security-group rules. For example:

- EKS node security group to Redis security group on 6379.
- EKS node/app security group to RDS security group on the database port.
- Admin bastion/VPN security group to Jenkins on 22/8080.

### 10. NAT gateway design is not highly available

Location: `modules/networking/main.tf`, lines 66-81 and 104-115

What is wrong:

Only one NAT gateway is created in the first public subnet, and all private subnets route through it. This is cheaper, but it creates an AZ dependency and possible cross-AZ data charges.

Best practice:

For production, use one NAT gateway per AZ and one private route table per AZ. For dev, single NAT is acceptable to save cost, but it should be an explicit environment choice.

### 11. ECR lifecycle policy description does not match behavior

Location: `modules/ecr/main.tf`, lines 11-28

What is wrong:

The description says "Keep last 10 images, remove untagged after 14 days", but the rule only expires untagged images after 14 days. It does not keep last 10 tagged images.

Best practice:

Either fix the description or add a second lifecycle rule for tagged images.

### 12. EKS node group is missing production hardening options

Location: `modules/eks/main.tf`, lines 114 onward

What is wrong:

The node group uses a single instance type and no labels, taints, disk size, capacity type, update config, launch template, or autoscaler/Karpenter integration.

Best practice:

Add variables for:

- `capacity_type` such as `ON_DEMAND` or `SPOT`
- multiple `instance_types`
- node disk size
- labels and taints
- rolling update max unavailable
- optional launch template for IMDSv2 and bootstrap settings

### 13. Provider and tool versions should be more consistent

Locations:

- Root modules require Terraform `>= 1.2`
- Jenkins installs Terraform `1.12.2`
- Lock files exist in multiple locations

What is wrong:

The repo allows old Terraform versions locally but CI installs a much newer fixed version. This can create different behavior between local and CI runs.

Best practice:

Pin the supported Terraform version range closer to what CI uses, for example:

```hcl
required_version = ">= 1.12, < 2.0"
```

Commit one `.terraform.lock.hcl` per root module and avoid creating unused root-level lock files unless the repo root is also a Terraform root module.

## Good Things You Already Did

- Modules are separated by concern: networking, EKS, database, ECR, Jenkins, and secrets.
- Environment tfvars are present for app-cluster.
- S3 backend is used for app-cluster state.
- Provider versions are constrained.
- Jenkins pipeline includes `terraform fmt -check`, `terraform validate`, plan, approval, and apply.
- ECR scan-on-push and lifecycle policy are included.
- EKS worker nodes are placed in private app subnets.
- RDS is not publicly accessible.
- ArgoCD is installed declaratively through Terraform/Helm.

## Validation Results

Commands run:

```bash
terraform fmt -check -recursive
```

Result: passed.

```bash
terraform validate
```

Result for `infrastructure/app-cluster`: failed because local provider plugins are not fully initialized. Terraform reported missing `hashicorp/kubernetes` and `hashicorp/time` providers and suggested running `terraform init`.

Result for `infrastructure/shared-services`: failed while loading the local AWS provider plugin schema. The provider binary exists, but Terraform could not complete the plugin handshake.

Next validation step:

Run fresh init for each root module with the correct backend config, then re-run validation:

```bash
cd infrastructure/app-cluster
terraform init -reconfigure -backend-config=../../environments/app-cluster/dev-backend.hcl
terraform validate

cd ../shared-services
terraform init -reconfigure -backend-config=../../environments/shared-services/shared-services-backend.hcl
terraform validate
```

## Recommended Fix Order

1. Remove public admin exposure: restrict EKS API, Jenkins, and ArgoCD CIDRs.
2. Remove Jenkins `AdministratorAccess` and replace it with scoped deploy roles.
3. Fix the incorrect RDS/Redis SSM parameter.
4. Replace `local-exec` secret management with native Terraform resources.
5. Add backend config for shared-services and fill staging/prod backend files.
6. Fill prod/staging tfvars and remove risky dev defaults from root variables.
7. Harden RDS defaults for non-dev environments.
8. Improve security group rules to use source security groups.
9. Decide per environment whether single NAT is acceptable.
10. Clean up provider lock files and align Terraform versions.

## Notes Checked Against Current AWS EKS Support

The configured EKS version `1.36` is currently supported by Amazon EKS. AWS documentation says EKS `1.36` was released on June 2, 2026, is in standard support until August 2, 2027, and extended support until August 2, 2028.

Source: AWS EKS Kubernetes version lifecycle documentation.
