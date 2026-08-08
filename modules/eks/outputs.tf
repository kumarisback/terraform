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
