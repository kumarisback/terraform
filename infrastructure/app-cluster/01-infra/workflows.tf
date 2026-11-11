# ---------------------------------------------------------
# Argo Workflows and Argo Events in the cloud (roadmap step 21, learning
# topic 21; gitops docs/WORKFLOWS.md). Off by default; dev turns it on.
#
# - An S3 bucket for workflows' artifacts and archived step logs, kept 30
#   days. Workflows reach it with their own IRSA roles; the controller
#   needs no AWS access.
# - Role ci_builder: pushes the services' images to ECR (the CI pipeline,
#   gitops automation/base/ci-build.yaml).
# - With the events archive on too (streaming.tf): every new archive file
#   is announced on an SQS queue, which Argo Events reads to start a
#   workflow that checks the file (automation/dev/archive-check.yaml).
#
# Costs: S3 storage of logs (megabytes), SQS requests (a few thousand a
# month, inside the free tier).
# ---------------------------------------------------------
locals {
  workflow_artifacts_bucket = "${var.project_name}-${var.environment}-workflow-artifacts-${data.aws_caller_identity.current.account_id}"
  archive_uploads_queue     = "${var.project_name}-${var.environment}-archive-uploads"
  archive_check_enabled     = var.enable_argo_workflows && var.enable_events_archive

  # Read and write the artifact bucket: every workflow pod uploads its
  # log and outputs there, and downloads its inputs.
  workflow_artifacts_statement = {
    Effect   = "Allow"
    Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    Resource = "arn:aws:s3:::${local.workflow_artifacts_bucket}/*"
  }

  # Merged into module "eks"'s irsa_roles (main.tf). ServiceAccounts in
  # namespace argo: argo-workflow (the workflows' default, from the
  # argo-workflows chart), ci-builder and archive-uploads-reader (gitops
  # automation/).
  workflows_irsa_roles = !var.enable_argo_workflows ? {} : merge(
    {
      argo_workflow = {
        namespace       = "argo"
        service_account = "argo-workflow"
        inline_policy_json = jsonencode({
          Version = "2012-10-17"
          Statement = concat(
            [local.workflow_artifacts_statement],
            # The archive check reads the file it checks, nothing else.
            local.archive_check_enabled ? [{
              Effect   = "Allow"
              Action   = ["s3:GetObject"]
              Resource = "arn:aws:s3:::${local.events_archive_bucket}/*"
            }] : []
          )
        })
      }
      ci_builder = {
        namespace       = "argo"
        service_account = "ci-builder"
        inline_policy_json = jsonencode({
          Version = "2012-10-17"
          Statement = [
            local.workflow_artifacts_statement,
            # A registry login; the token is scoped by the statement below.
            {
              Effect   = "Allow"
              Action   = ["ecr:GetAuthorizationToken"]
              Resource = "*"
            },
            # Push to the services' repositories (tf shared-services), and
            # nothing else: no deleting, no other repositories.
            {
              Effect = "Allow"
              Action = [
                "ecr:BatchCheckLayerAvailability",
                "ecr:BatchGetImage",
                "ecr:CompleteLayerUpload",
                "ecr:InitiateLayerUpload",
                "ecr:PutImage",
                "ecr:UploadLayerPart",
              ]
              Resource = [
                for repo in var.ci_push_repositories :
                "arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/${repo}"
              ]
            },
          ]
        })
      }
    },
    local.archive_check_enabled ? {
      archive_uploads_reader = {
        namespace       = "argo"
        service_account = "archive-uploads-reader"
        inline_policy_json = jsonencode({
          Version = "2012-10-17"
          Statement = [
            {
              Effect   = "Allow"
              Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
              Resource = "arn:aws:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${local.archive_uploads_queue}"
            }
          ]
        })
      }
    } : {}
  )
}

resource "aws_s3_bucket" "workflow_artifacts" {
  count = var.enable_argo_workflows ? 1 : 0

  bucket        = local.workflow_artifacts_bucket
  force_destroy = var.environment == "dev"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-workflow-artifacts"
  })
}

resource "aws_s3_bucket_public_access_block" "workflow_artifacts" {
  count = var.enable_argo_workflows ? 1 : 0

  bucket                  = aws_s3_bucket.workflow_artifacts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "workflow_artifacts" {
  count = var.enable_argo_workflows ? 1 : 0

  bucket = aws_s3_bucket.workflow_artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Logs and outputs are for looking into recent runs, not for keeping.
resource "aws_s3_bucket_lifecycle_configuration" "workflow_artifacts" {
  count = var.enable_argo_workflows ? 1 : 0

  bucket = aws_s3_bucket.workflow_artifacts[0].id

  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Refuse plain-HTTP requests, whoever makes them; the AWS SDK uses HTTPS.
data "aws_iam_policy_document" "workflow_artifacts_tls_only" {
  count = var.enable_argo_workflows ? 1 : 0

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.workflow_artifacts[0].arn, "${aws_s3_bucket.workflow_artifacts[0].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "workflow_artifacts" {
  count = var.enable_argo_workflows ? 1 : 0

  bucket = aws_s3_bucket.workflow_artifacts[0].id
  policy = data.aws_iam_policy_document.workflow_artifacts_tls_only[0].json

  depends_on = [aws_s3_bucket_public_access_block.workflow_artifacts]
}

# ---------------------------------------------------------
# New archive files announced on SQS, for Argo Events' archive check.
# ---------------------------------------------------------
resource "aws_sqs_queue" "archive_uploads" {
  count = local.archive_check_enabled ? 1 : 0

  name                       = local.archive_uploads_queue
  message_retention_seconds  = 345600 # 4 days: a weekend without the cluster loses nothing
  receive_wait_time_seconds  = 20
  visibility_timeout_seconds = 120
  sqs_managed_sse_enabled    = true

  tags = local.common_tags
}

# Only S3, and only for the events archive bucket, may send to it.
data "aws_iam_policy_document" "archive_uploads" {
  count = local.archive_check_enabled ? 1 : 0

  statement {
    sid       = "EventsArchiveNotifications"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.archive_uploads[0].arn]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.events_archive[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "archive_uploads" {
  count = local.archive_check_enabled ? 1 : 0

  queue_url = aws_sqs_queue.archive_uploads[0].id
  policy    = data.aws_iam_policy_document.archive_uploads[0].json
}

# Every finished archive file (Kafka Connect writes .jsonl.gz objects).
resource "aws_s3_bucket_notification" "events_archive" {
  count = local.archive_check_enabled ? 1 : 0

  bucket = aws_s3_bucket.events_archive[0].id

  queue {
    queue_arn     = aws_sqs_queue.archive_uploads[0].arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".jsonl.gz"
  }

  # S3 checks it may send to the queue when the notification is set.
  depends_on = [aws_sqs_queue_policy.archive_uploads]
}
