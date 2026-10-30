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

output "observability_bucket_names" {
  description = "S3 bucket name per observability component (loki, tempo). gitops addons/values/<env>/{loki,tempo}.yaml must use the same names."
  value       = { for k, b in aws_s3_bucket.observability : k => b.bucket }
}

output "efs_file_system_id" {
  description = "The shared EFS file system; 02-services names it in the efs StorageClass."
  value       = aws_efs_file_system.shared.id
}

output "synthetics_canary_name" {
  description = "The CloudWatch Synthetics canary checking the app from outside (null while synthetics_base_url is unset)."
  value       = one(aws_synthetics_canary.app[*].name)
}

output "synthetics_alarm_topic_arn" {
  description = "SNS topic the canary's alarm notifies; subscribe PagerDuty, Slack (AWS Chatbot) or email to it."
  value       = one(aws_sns_topic.synthetics_alarms[*].arn)
}

output "events_archive_bucket_name" {
  description = "The Kafka events archive bucket (null while enable_events_archive is off). gitops streaming/<env>/kustomization.yaml must name the same bucket."
  value       = one(aws_s3_bucket.events_archive[*].bucket)
}

output "msk_bootstrap_brokers" {
  description = "MSK Serverless bootstrap servers for IAM sign-in (null while enable_msk is off): the value of kafka.msk.bootstrapServers in gitops."
  value       = one(module.msk[*].bootstrap_brokers_sasl_iam)
}

output "msk_cluster_arn" {
  value = one(module.msk[*].cluster_arn)
}
