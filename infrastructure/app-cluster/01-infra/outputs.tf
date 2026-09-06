output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "vpc_id" {
  value = module.networking.vpc_id
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  value = module.eks.oidc_provider_url
}

output "irsa_role_arns" {
  value = module.eks.irsa_role_arns
}

output "karpenter_instance_profile_name" {
  description = "Name of the instance profile for Karpenter node instances"
  value       = aws_iam_instance_profile.karpenter.name
}

output "karpenter_interruption_queue_name" {
  description = "Name of SQS Queue for Karpenter Spot Interruption handling"
  value       = aws_sqs_queue.karpenter_interruption.name
}