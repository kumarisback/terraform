data "aws_secretsmanager_secret" "app_secrets" {
  count = var.manage_secret ? 0 : 1
  name  = var.secret_name
  arn   = var.secret_arn != "" ? var.secret_arn : null
}

data "aws_secretsmanager_secret_version" "app_secrets_val" {
  count     = var.manage_secret ? 0 : 1
  secret_id = data.aws_secretsmanager_secret.app_secrets[0].id
}

locals {
  secret_values = var.manage_secret ? var.secret_values : jsondecode(data.aws_secretsmanager_secret_version.app_secrets_val[0].secret_string)
}

# When manage_secret is true, create or update the secret using the aws CLI.
# This approach uses a local-exec to either create the secret or add a new version
# so it works whether the secret already exists or not.
resource "null_resource" "ensure_secret" {
  count = var.manage_secret ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOC
      set -e
      secret_name="${var.secret_name}"
      secret_json='${jsonencode(var.secret_values)}'
      if ! aws secretsmanager create-secret --name "$secret_name" --secret-string "$secret_json" >/dev/null 2>&1; then
        aws secretsmanager put-secret-value --secret-id "$secret_name" --secret-string "$secret_json"
      fi
    EOC
  }

  triggers = {
    secret_json = jsonencode(var.secret_values)
  }
}
