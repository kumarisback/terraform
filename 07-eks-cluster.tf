# 1. EKS Cluster Control Plane
resource "aws_eks_cluster" "main" {
  name     = "microservices-eks"
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = "1.36"

  vpc_config {
    subnet_ids              = aws_subnet.private_app[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]

  tags = {
    Name = "microservices-eks"
  }
}

# 2. Managed Node Group
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "microservices-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.private_app[*].id

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 1
  }

  instance_types = ["t3.medium"]
  capacity_type  = "ON_DEMAND"

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_read_only
  ]

  tags = {
    Name = "microservices-eks-nodes"
  }
}

# 3. Useful Outputs for kubectl and OIDC integration
output "eks_cluster_name" {
  description = "Name of the EKS Cluster"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "Endpoint for EKS Control Plane"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_oidc_issuer" {
  description = "OIDC Issuer URL for IRSA configuration"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}