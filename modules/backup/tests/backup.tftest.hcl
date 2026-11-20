# terraform test (run in modules/backup: terraform init && terraform test).
# The AWS provider is mocked: nothing created, nothing billed.
mock_provider "aws" {
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:602367507570:microservices-dev-backup-events"
    }
  }
}

variables {
  name        = "microservices"
  environment = "dev"
}

run "tagged_resources_daily_and_monthly" {
  command = plan

  assert {
    condition = (
      one(aws_backup_selection.tagged.condition).string_equals != null &&
      contains(aws_backup_selection.tagged.resources, "arn:aws:rds:*:*:db:*") &&
      contains(aws_backup_selection.tagged.resources, "arn:aws:ec2:*:*:volume/*") &&
      contains(aws_backup_selection.tagged.resources, "arn:aws:elasticfilesystem:*:*:file-system/*")
    )
    error_message = "RDS, EBS and EFS, chosen by tag."
  }

  assert {
    condition     = toset([for r in aws_backup_plan.this.rule : r.rule_name]) == toset(["daily", "monthly"])
    error_message = "A daily and a monthly rule."
  }

  assert {
    condition     = length(aws_backup_vault_lock_configuration.this) == 0 && !aws_backup_vault.this.force_destroy
    error_message = "No lock unless asked; never force-destroyed."
  }
}

run "locked_in_compliance_mode" {
  command = plan

  variables {
    vault_lock = {
      min_retention_days    = 7
      max_retention_days    = 400
      compliance_after_days = 3
    }
  }

  assert {
    condition     = aws_backup_vault_lock_configuration.this[0].changeable_for_days == 3
    error_message = "Compliance mode after three days."
  }
}

run "retention_outside_the_lock" {
  command = plan

  variables {
    vault_lock = {
      min_retention_days = 60
      max_retention_days = 400
    }
  }

  expect_failures = [aws_backup_plan.this]
}

run "compliance_too_soon" {
  command = plan

  variables {
    vault_lock = {
      min_retention_days    = 7
      max_retention_days    = 400
      compliance_after_days = 1
    }
  }

  expect_failures = [var.vault_lock]
}

run "copies_when_asked" {
  command = plan

  variables {
    copy_to_vault_arn = "arn:aws:backup:us-west-2:602367507570:backup-vault:microservices-dev-backups"
  }

  assert {
    condition     = length([for r in aws_backup_plan.this.rule : r if r.rule_name == "daily" && length(r.copy_action) == 1]) == 1
    error_message = "Dailies copied to the other vault."
  }
}
