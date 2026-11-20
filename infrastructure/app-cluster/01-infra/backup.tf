# ---------------------------------------------------------
# Backups (roadmap step 25, learning topic 25, gitops docs/BACKUP-DR.md).
# Both off by default: they bill for what they keep.
#
#   AWS Backup  modules/backup: RDS, EBS volumes and EFS tagged Backup=daily
#               (the RDS instance and the shared EFS file system are; in
#               gitops, StorageClass gp3-retain's volumes), every night and
#               every month, into a vault of their own.
#   Velero      Kubernetes itself: the objects of the namespaces it backs up
#               and their volumes' data, into an S3 bucket of its own, with
#               an IRSA role for its ServiceAccount (gitops addons/backup).
# ---------------------------------------------------------

module "backup" {
  source = "../../../modules/backup"
  count  = var.enable_aws_backup ? 1 : 0

  name               = var.project_name
  environment        = var.environment
  vault_lock         = var.backup_vault_lock
  copy_to_vault_arn  = var.backup_copy_to_vault_arn
  notification_email = var.backup_notification_email
}

locals {
  velero_bucket = "${var.project_name}-${var.environment}-velero-${data.aws_caller_identity.current.account_id}"

  # A for-if rather than cond ? {...} : {}, whose two object types differ.
  velero_irsa_roles = {
    for k, v in {
      velero = {
        namespace = "velero"
        # The Velero server and its node agents (which move volume data to
        # the bucket) both run as this ServiceAccount.
        service_account = "velero-server"
        inline_policy_json = jsonencode({
          Version = "2012-10-17"
          Statement = [
            {
              Effect   = "Allow"
              Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
              Resource = "arn:aws:s3:::${local.velero_bucket}/*"
            },
            {
              Effect   = "Allow"
              Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
              Resource = "arn:aws:s3:::${local.velero_bucket}"
            }
          ]
        })
      }
    } : k => v if var.enable_velero
  }
}

resource "aws_s3_bucket" "velero" {
  count  = var.enable_velero ? 1 : 0
  bucket = local.velero_bucket

  tags = merge(local.common_tags, {
    Name = local.velero_bucket
  })
}

# Versioned, and older versions kept two weeks: a backup deleted (by Velero's
# expiry, a mistake, or someone who got the role) can still be recovered for
# that long. Velero itself decides how long a backup lives (its TTL).
resource "aws_s3_bucket_versioning" "velero" {
  count  = var.enable_velero ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  count  = var.enable_velero ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  rule {
    id     = "deleted-backups"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 14
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.velero]
}

# Backups contain the namespaces' Secrets: encrypted, private, this
# account's only.
resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  count  = var.enable_velero ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  count  = var.enable_velero ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "velero" {
  count  = var.enable_velero ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
