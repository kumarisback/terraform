# ---------------------------------------------------------
# AWS-managed monitoring, next to the self-hosted stack in gitops
# (roadmap step 11, learning topic 11). Both are off by default: they bill
# while on.
#
#   Container Insights   amazon-cloudwatch-observability add-on: a CloudWatch
#                        agent on every node sends node, pod and container
#                        metrics to CloudWatch, to compare with Prometheus.
#                        Its container logs (Fluent Bit) stay off: Alloy
#                        already ships them to Loki, and CloudWatch would
#                        bill for them a second time.
#   Synthetics canary    The app's synthetic checks from outside the cluster,
#                        through its public URL, every 5 minutes. An alarm
#                        on failed runs notifies an SNS topic.
# ---------------------------------------------------------

# --- Container Insights ----------------------------------------------------
# The agent's IRSA role, merged into module "eks"'s irsa_roles (main.tf).
# A for-if rather than cond ? {...} : {}, whose two object types differ.
locals {
  container_insights_irsa_roles = {
    for k, v in {
      cloudwatch_agent = {
        namespace       = "amazon-cloudwatch"
        service_account = "cloudwatch-agent"
        policy_arns     = ["arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"]
      }
    } : k => v if var.enable_container_insights
  }
}

data "aws_eks_addon_version" "cloudwatch_observability" {
  count = var.enable_container_insights ? 1 : 0

  addon_name         = "amazon-cloudwatch-observability"
  kubernetes_version = var.cluster_version
}

resource "aws_eks_addon" "cloudwatch_observability" {
  count = var.enable_container_insights ? 1 : 0

  cluster_name             = module.eks.cluster_name
  addon_name               = "amazon-cloudwatch-observability"
  addon_version            = lookup(var.eks_addon_versions, "amazon-cloudwatch-observability", data.aws_eks_addon_version.cloudwatch_observability[0].version)
  service_account_role_arn = module.eks.irsa_role_arns["cloudwatch_agent"]
  configuration_values = jsonencode({
    containerLogs = { enabled = false }
  })
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = local.common_tags

  depends_on = [module.eks]
}

# --- Synthetics canary -----------------------------------------------------
# On once synthetics_base_url is set: the ALB's DNS name after the first
# ArgoCD sync, the domain once it exists (see the variable).
locals {
  synthetics_enabled = var.synthetics_base_url != null
  canary_name        = "${var.environment}-app-checks"
  canary_script      = "${path.module}/synthetics/canary.js"
}

# Run reports, HAR files and logs; disposable.
resource "aws_s3_bucket" "synthetics" {
  count = local.synthetics_enabled ? 1 : 0

  bucket        = "${var.project_name}-${var.environment}-synthetics-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-synthetics"
  })
}

resource "aws_s3_bucket_public_access_block" "synthetics" {
  count = local.synthetics_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.synthetics[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "synthetics" {
  count = local.synthetics_enabled ? 1 : 0

  bucket = aws_s3_bucket.synthetics[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "synthetics" {
  count = local.synthetics_enabled ? 1 : 0

  bucket = aws_s3_bucket.synthetics[0].id

  rule {
    id     = "expire-run-artifacts"
    status = "Enabled"

    filter {}

    # As long as the canary keeps failed runs (failure_retention_period).
    expiration {
      days = 31
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# The canary runs as a Lambda function with this role: write its artifacts,
# its own logs, and metrics in the CloudWatchSynthetics namespace only.
data "aws_iam_policy_document" "canary_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "canary" {
  count = local.synthetics_enabled ? 1 : 0

  name               = "${var.project_name}-${var.environment}-synthetics-canary"
  assume_role_policy = data.aws_iam_policy_document.canary_assume.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "canary" {
  count = local.synthetics_enabled ? 1 : 0

  statement {
    sid       = "WriteArtifacts"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.synthetics[0].arn}/*"]
  }

  statement {
    sid       = "LocateArtifactBucket"
    actions   = ["s3:GetBucketLocation"]
    resources = [aws_s3_bucket.synthetics[0].arn]
  }

  # Synthetics lists buckets to check the artifact location exists; this
  # grants names only, not access.
  statement {
    sid       = "ListBuckets"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/cwsyn-${local.canary_name}-*"]
  }

  statement {
    sid       = "PublishSyntheticsMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["CloudWatchSynthetics"]
    }
  }
}

resource "aws_iam_role_policy" "canary" {
  count = local.synthetics_enabled ? 1 : 0

  name   = "synthetics-canary"
  role   = aws_iam_role.canary[0].id
  policy = data.aws_iam_policy_document.canary[0].json
}

# Pinned (synthetics_runtime_version), looked up to fail at plan time if
# this region doesn't have it.
data "aws_synthetics_runtime_version" "canary" {
  count = local.synthetics_enabled ? 1 : 0

  prefix  = "syn-nodejs-puppeteer"
  version = var.synthetics_runtime_version
}

# AWS announces a runtime's deprecation date ahead of time; a warning on
# every plan from then on, before new runs stop.
check "synthetics_runtime_supported" {
  assert {
    condition     = alltrue([for r in data.aws_synthetics_runtime_version.canary : r.deprecation_date == null || r.deprecation_date == ""])
    error_message = "Canary runtime deprecation scheduled: ${join(", ", [for r in data.aws_synthetics_runtime_version.canary : "${r.version_name} on ${coalesce(r.deprecation_date, "?")}"])}. Raise synthetics_runtime_version (learning topic 11)."
  }
}

# The script's hash is in the file name: the canary resource only notices a
# new zip_file path, not new contents at the same path.
data "archive_file" "canary" {
  count = local.synthetics_enabled ? 1 : 0

  type        = "zip"
  output_path = "${path.module}/.build/canary-${substr(filesha256(local.canary_script), 0, 12)}.zip"

  source {
    content  = file(local.canary_script)
    filename = "nodejs/node_modules/canary.js"
  }
}

resource "aws_synthetics_canary" "app" {
  count = local.synthetics_enabled ? 1 : 0

  name                 = local.canary_name
  artifact_s3_location = "s3://${aws_s3_bucket.synthetics[0].id}/${local.canary_name}/"
  execution_role_arn   = aws_iam_role.canary[0].arn
  runtime_version      = data.aws_synthetics_runtime_version.canary[0].version_name
  handler              = "canary.handler"
  zip_file             = data.archive_file.canary[0].output_path
  start_canary         = true
  # Remove the canary's Lambda function and layer with it, not leave them.
  delete_lambda = true

  success_retention_period = 7
  failure_retention_period = 31

  schedule {
    expression = "rate(5 minutes)"
  }

  run_config {
    timeout_in_seconds = 60
    environment_variables = {
      BASE_URL = var.synthetics_base_url
    }
  }

  tags = local.common_tags

  depends_on = [aws_iam_role_policy.canary, aws_s3_bucket_public_access_block.synthetics]
}

# Not KMS-encrypted: CloudWatch alarms can't publish to a topic encrypted
# with the AWS-managed key (aws/sns, whose policy can't grant CloudWatch),
# and these messages hold no secrets: an alarm name, a state, a URL.
resource "aws_sns_topic" "synthetics_alarms" {
  count = local.synthetics_enabled ? 1 : 0

  name = "${var.project_name}-${var.environment}-synthetics-alarms"

  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "synthetics_alarm_email" {
  count = local.synthetics_enabled && var.synthetics_alarm_email != null ? 1 : 0

  topic_arn = aws_sns_topic.synthetics_alarms[0].arn
  protocol  = "email"
  endpoint  = var.synthetics_alarm_email
}

# Each run either passes (100) or fails (0). Two failed runs out of three
# (10 of 15 minutes) alarm, so one flaky run doesn't. No data at all means
# the canary isn't running, which is as bad: nobody is checking.
resource "aws_cloudwatch_metric_alarm" "canary_failing" {
  count = local.synthetics_enabled ? 1 : 0

  alarm_name          = "${var.project_name}-${var.environment}-synthetics-failing"
  alarm_description   = "Outside-in checks of ${var.synthetics_base_url} (canary ${local.canary_name}) failed in 2 of the last 3 runs. Which check: the canary's run report. Runbook: gitops docs/runbooks.md#endpointdown"
  namespace           = "CloudWatchSynthetics"
  metric_name         = "SuccessPercent"
  dimensions          = { CanaryName = aws_synthetics_canary.app[0].name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 100
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.synthetics_alarms[0].arn]
  ok_actions          = [aws_sns_topic.synthetics_alarms[0].arn]

  tags = local.common_tags
}
