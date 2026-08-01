# 1. IAM Policy for Secrets Manager & SSM Parameter Store access
resource "aws_iam_policy" "external_secrets" {
  name        = "EKSExternalSecretsOperatorPolicy"
  path        = "/"
  description = "Allows External Secrets Operator to read secrets from AWS Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "EKSExternalSecretsOperatorPolicy"
  }
}

# 2. IAM Role with OIDC Trust Policy
resource "aws_iam_role" "external_secrets" {
  name = "AmazonEKS_ExternalSecretsOperatorRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:external-secrets:external-secrets-sa"
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name = "ExternalSecretsOperatorRole"
  }
}

# 3. Attach Policy to Role
resource "aws_iam_role_policy_attachment" "external_secrets" {
  policy_arn = aws_iam_policy.external_secrets.arn
  role       = aws_iam_role.external_secrets.name
}

# 4. Output Role ARN for Kubernetes / Helm integration
output "external_secrets_role_arn" {
  description = "ARN of the IRSA role for External Secrets Operator"
  value       = aws_iam_role.external_secrets.arn
}