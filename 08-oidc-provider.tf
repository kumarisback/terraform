# 1. Fetch the TLS Certificate for the Cluster's OIDC Issuer URL
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# 2. Register the IAM OIDC Provider tied to the EKS Cluster
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name = "microservices-eks-oidc"
  }
}

# Output the OIDC Provider ARN (used by upcoming IRSA roles)
output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC Provider for IRSA"
  value       = aws_iam_openid_connect_provider.eks.arn
}