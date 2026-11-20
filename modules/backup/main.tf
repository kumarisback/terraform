# AWS Backup for the environment's data stores (roadmap step 25, learning
# topic 25): RDS, EBS volumes and EFS file systems tagged Backup=<tag value>,
# copied into a vault of their own, on a schedule, kept for a set time.
#
# Why on top of RDS's own automated backups and Velero: those live with the
# thing they protect (deleting the instance or the cluster's bucket can take
# them along); a vault is separate, can be locked against deletion (vault
# lock), and can copy to another region or account.

locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = var.name
  }
  name = "${var.name}-${var.environment}"
}

resource "aws_backup_vault" "this" {
  name = "${local.name}-backups"
  # null: AWS Backup's own managed key (aws/backup).
  kms_key_arn = var.kms_key_arn
  # A vault with recovery points can't be deleted; force_destroy would delete
  # them all with it. Never for a vault that matters.
  force_destroy = false

  tags = local.common_tags
}

# Vault lock: recovery points can't be deleted (by anyone, root included)
# before min_retention_days, and no rule may keep them longer than
# max_retention_days. Governance mode (changeable_for_days null) can be
# removed by someone with the permission; compliance mode becomes immutable
# after changeable_for_days, for the vault's lifetime. Off by default:
# learning topic 25 says when to turn it on.
resource "aws_backup_vault_lock_configuration" "this" {
  count = var.vault_lock == null ? 0 : 1

  backup_vault_name   = aws_backup_vault.this.name
  min_retention_days  = var.vault_lock.min_retention_days
  max_retention_days  = var.vault_lock.max_retention_days
  changeable_for_days = var.vault_lock.compliance_after_days
}

resource "aws_iam_role" "backup" {
  name = "${local.name}-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
  ])

  role       = aws_iam_role.backup.name
  policy_arn = each.value
}

resource "aws_backup_plan" "this" {
  name = "${local.name}-plan"

  # Every night, kept daily_retention_days.
  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = var.daily_schedule
    start_window      = 60
    completion_window = 360

    lifecycle {
      delete_after = var.daily_retention_days
    }

    dynamic "copy_action" {
      for_each = var.copy_to_vault_arn == null ? [] : [1]
      content {
        destination_vault_arn = var.copy_to_vault_arn
        lifecycle {
          delete_after = var.daily_retention_days
        }
      }
    }
  }

  # The first of each month, kept monthly_retention_days: older points to go
  # back to than the dailies reach.
  rule {
    rule_name         = "monthly"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 4 1 * ? *)"
    start_window      = 60
    completion_window = 720

    lifecycle {
      delete_after = var.monthly_retention_days
    }
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = var.vault_lock == null ? true : var.daily_retention_days >= var.vault_lock.min_retention_days && var.monthly_retention_days <= var.vault_lock.max_retention_days
      error_message = "The plan's retentions must fit inside the vault lock's min and max retention."
    }
  }
}

# What gets backed up: anything of these kinds carrying the tag. Tagging is
# the opt-in, done where the resource is made (RDS: modules/database
# extra_tags; EBS: gitops StorageClass gp3-retain; EFS: 01-infra).
resource "aws_backup_selection" "tagged" {
  name         = "${local.name}-tagged"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [
    "arn:aws:rds:*:*:db:*",
    "arn:aws:ec2:*:*:volume/*",
    "arn:aws:elasticfilesystem:*:*:file-system/*",
  ]

  condition {
    string_equals {
      key   = "aws:ResourceTag/${var.selection_tag.key}"
      value = var.selection_tag.value
    }
  }
}

# Failed backups and restores, by e-mail through SNS.
resource "aws_sns_topic" "backup" {
  name = "${local.name}-backup-events"
  tags = local.common_tags
}

resource "aws_sns_topic_policy" "backup" {
  arn = aws_sns_topic.backup.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.backup.arn
    }]
  })
}

resource "aws_backup_vault_notifications" "this" {
  backup_vault_name = aws_backup_vault.this.name
  sns_topic_arn     = aws_sns_topic.backup.arn
  backup_vault_events = [
    "BACKUP_JOB_FAILED",
    "BACKUP_JOB_EXPIRED",
    "COPY_JOB_FAILED",
    "RESTORE_JOB_COMPLETED",
    "S3_BACKUP_OBJECT_FAILED",
  ]

  depends_on = [aws_sns_topic_policy.backup]
}

resource "aws_sns_topic_subscription" "email" {
  count = var.notification_email == null ? 0 : 1

  topic_arn = aws_sns_topic.backup.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
