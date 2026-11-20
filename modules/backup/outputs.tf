output "vault_name" {
  description = "The backup vault"
  value       = aws_backup_vault.this.name
}

output "vault_arn" {
  description = "The backup vault's ARN (another environment's copy_to_vault_arn, for cross-region copies)"
  value       = aws_backup_vault.this.arn
}

output "plan_id" {
  description = "The backup plan"
  value       = aws_backup_plan.this.id
}

output "role_arn" {
  description = "The role AWS Backup backs up and restores with"
  value       = aws_iam_role.backup.arn
}

output "notifications_topic_arn" {
  description = "SNS topic for failed backups and finished restores"
  value       = aws_sns_topic.backup.arn
}
