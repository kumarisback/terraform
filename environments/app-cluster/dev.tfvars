aws_region                = "us-east-1"
project_name              = "microservices"
environment               = "dev"
vpc_cidr                  = "10.10.0.0/16"
public_subnet_cidrs       = ["10.10.1.0/24", "10.10.2.0/24"]
private_app_subnet_cidrs  = ["10.10.11.0/24", "10.10.12.0/24"]
private_data_subnet_cidrs = ["10.10.21.0/24", "10.10.22.0/24"]
enable_nat_gateway        = true

# EKS API access.
# Best practice: set this to your public IP as /32 or a VPN CIDR.
eks_endpoint_public_access = false
eks_public_access_cidrs    = []

# ArgoCD UI: no public LoadBalancer — access it via `kubectl port-forward`
# instead (see README.md).
enable_argocd_loadbalancer = false
argocd_allowed_cidrs       = []

# Deploy only dev's own app set (+ shared platform components) into this
# cluster — NOT bootstrap/projects, which would also deploy staging's and
# prod's full app sets into this same cluster.
argocd_gitops_repo_path = "bootstrap/envs/dev"

# EKS Access Configuration
eks_admin_users = ["arn:aws:iam::602367507570:user/terraform"]

# Read-only tier (AmazonEKSViewPolicy) — add IAM user/role ARNs here instead
# of eks_admin_users once you have a second identity that only needs to look
# around, e.g.:
# eks_viewer_users = ["arn:aws:iam::602367507570:user/some-teammate"]
eks_viewer_users = []

# Custom RBAC-group tier — bypasses AWS-managed policies entirely; access is
# governed purely by the ClusterRole/ClusterRoleBinding or RoleBinding in
# gitops/platform/rbac/ that reference these group names, e.g.:
# eks_group_mapped_users = {
#   "arn:aws:iam::602367507570:user/some-teammate" = ["sre"]
# }
eks_group_mapped_users = {
  "arn:aws:iam::602367507570:user/SRE_TEST" = ["sre"]
}

# AWS-managed monitoring next to the Prometheus stack (01-infra
# observability.tf, learning topic 11). Off: both bill while on. For the
# canary, set the ALB's DNS name after the first ArgoCD sync:
#   kubectl get ingress kong-gateway-proxy -n kong -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
enable_container_insights = false
# synthetics_base_url    = "http://<ALB DNS name>"
# synthetics_alarm_email = "you@example.com"

# The Kafka events archive (01-infra streaming.tf, learning topic 13): an
# S3 bucket and the role Kafka Connect writes to it with. On in dev, where
# gitops streaming/dev runs the connector. Costs cents: a few MB a month.
enable_events_archive = true

# Argo Workflows' artifact bucket and roles, and the queue announcing new
# archive files (01-infra workflows.tf, learning topic 21). On in dev, where
# gitops runs addons/automation. Costs cents.
enable_argo_workflows = true

# PostgreSQL on RDS for Unleash, the feature flag service (modules/database,
# roadmap step 23, learning topic 23). Off: Multi-AZ db.t4g.micro is about
# $25 a month, a replica or RDS Proxy more. For the step's exercises turn it
# on, then switch gitops feature-flags/dev to it (docs/DATABASE.md). A dev
# instance you mean to destroy afterwards: no deletion protection, a final
# snapshot named here.
# enable_rds                    = true
# rds_deletion_protection       = false
# rds_final_snapshot_identifier = "microservices-dev-rds-final"
# rds_apply_immediately         = true
# rds_read_replica              = true   # the replica-lag exercise
# rds_proxy                     = true   # the connection-pooling exercise
# database_alarm_email          = "you@example.com"
