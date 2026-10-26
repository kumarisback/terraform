# ---------------------------------------------------------
# The events archive (roadmap step 13, learning topic 13). A Kafka Connect
# S3 sink (gitops streaming/components/events-archive) copies every record
# of the orders and users topics into this bucket. Kafka keeps them for 7
# days; the archive for events_archive_retention_days.
#
# Off by default; dev turns it on (dev.tfvars), and gitops streaming/dev
# includes the component. An environment needs both or neither.
# ---------------------------------------------------------
locals {
  events_archive_bucket = "${var.project_name}-${var.environment}-events-archive-${data.aws_caller_identity.current.account_id}"

  # The Connect workers' IRSA role, merged into module "eks"'s irsa_roles
  # (main.tf). Strimzi names the ServiceAccount <KafkaConnect name>-connect.
  # The sink only uploads (multipart: create, upload parts, complete or
  # abort); it never lists, reads or deletes. The ARN is built from the
  # name: the bucket resource doesn't exist while this is off.
  events_archive_irsa_roles = {
    for k, v in {
      kafka_connect = {
        namespace       = "kafka"
        service_account = "events-connect-connect"
        inline_policy_json = jsonencode({
          Version = "2012-10-17"
          Statement = [
            {
              Effect   = "Allow"
              Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
              Resource = "arn:aws:s3:::${local.events_archive_bucket}/*"
            }
          ]
        })
      }
    } : k => v if var.enable_events_archive
  }
}

resource "aws_s3_bucket" "events_archive" {
  count = var.enable_events_archive ? 1 : 0

  bucket        = local.events_archive_bucket
  force_destroy = var.environment == "dev"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-events-archive"
  })
}

resource "aws_s3_bucket_public_access_block" "events_archive" {
  count = var.enable_events_archive ? 1 : 0

  bucket                  = aws_s3_bucket.events_archive[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "events_archive" {
  count = var.enable_events_archive ? 1 : 0

  bucket = aws_s3_bucket.events_archive[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Refuse plain-HTTP requests, whoever makes them; the AWS SDK uses HTTPS.
data "aws_iam_policy_document" "events_archive_tls_only" {
  count = var.enable_events_archive ? 1 : 0

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.events_archive[0].arn, "${aws_s3_bucket.events_archive[0].arn}/*"]

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

resource "aws_s3_bucket_policy" "events_archive" {
  count = var.enable_events_archive ? 1 : 0

  bucket = aws_s3_bucket.events_archive[0].id
  policy = data.aws_iam_policy_document.events_archive_tls_only[0].json

  # A bucket policy can't be set while the public access block is being
  # created (S3 answers 409 OperationAborted).
  depends_on = [aws_s3_bucket_public_access_block.events_archive]
}

# No move to Standard-IA or Glacier: the files are small (gzipped, one per
# partition every few minutes), and those classes bill at least 128 KB per
# object plus a fee per transition, which costs more than it saves here.
resource "aws_s3_bucket_lifecycle_configuration" "events_archive" {
  count = var.enable_events_archive ? 1 : 0

  bucket = aws_s3_bucket.events_archive[0].id

  rule {
    id     = "expire-archived-events"
    status = "Enabled"

    filter {}

    expiration {
      days = var.events_archive_retention_days
    }

    # A worker that dies mid-upload leaves its parts behind; they bill
    # until removed.
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
