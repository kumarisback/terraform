output "cluster_role_arn" {
  description = "EKS cluster role ARN"
  value       = aws_iam_role.eks_cluster_role.arn
}

output "node_role_arn" {
  description = "EKS node role ARN"
  value       = aws_iam_role.eks_node_role.arn
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "EKS cluster certificate authority data"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for this cluster's issuer, used as the Federated principal for IRSA roles"
  value       = aws_iam_openid_connect_provider.eks_oidc.arn
}

output "oidc_provider_url" {
  description = "URL of this cluster's OIDC issuer"
  value       = aws_iam_openid_connect_provider.eks_oidc.url
}

output "irsa_role_arns" {
  description = "Map of IRSA role name (as keyed in var.irsa_roles) to its IAM role ARN"
  value       = { for k, r in aws_iam_role.irsa : k => r.arn }
}