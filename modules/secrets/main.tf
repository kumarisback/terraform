data "aws_secretsmanager_secret" "app_secrets" {
  count = !var.manage_secret && var.secret_arn == "" ? 1 : 0

  name = var.secret_name
}

data "aws_secretsmanager_secret_version" "app_secrets_val" {
  count = var.manage_secret ? 0 : 1

  secret_id = var.secret_arn != "" ? var.secret_arn : data.aws_secretsmanager_secret.app_secrets[0].id
}

resource "aws_secretsmanager_secret" "app_secrets" {
  count = var.manage_secret ? 1 : 0

  name                    = var.secret_name
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app_secrets" {
  count = var.manage_secret ? 1 : 0

  secret_id     = aws_secretsmanager_secret.app_secrets[0].id
  secret_string = jsonencode(var.secret_values)
}

locals {
  secret_values = var.manage_secret ? var.secret_values : jsondecode(data.aws_secretsmanager_secret_version.app_secrets_val[0].secret_string)
  secret_arn    = var.manage_secret ? aws_secretsmanager_secret.app_secrets[0].arn : (var.secret_arn != "" ? var.secret_arn : data.aws_secretsmanager_secret.app_secrets[0].arn)
}
