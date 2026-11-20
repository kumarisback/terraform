# Hardens an S3 bucket that holds Terraform state (roadmap step 25, learning
# topic 25). The buckets were created by hand before Terraform ran (a state
# bucket can't hold its own creation), so this manages their settings, not
# the buckets: it never deletes one.
#
# Versioning is the backup: every state write keeps the previous one, so a
# corrupted or wrongly applied state can be put back (learning topic 25,
# "restoring state"). The lifecycle keeps that history bounded.

resource "aws_s3_bucket_versioning" "this" {
  bucket = var.bucket

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = var.bucket

  rule {
    id     = "state-history"
    status = "Enabled"

    filter {}

    # Older state versions: the newest ones always, the rest for a while.
    noncurrent_version_expiration {
      noncurrent_days           = var.noncurrent_days
      newer_noncurrent_versions = var.keep_noncurrent_versions
    }

    # Uploads that never finished.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    # Delete markers left with nothing behind them (S3's own lock files,
    # *.tflock, leave these).
    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# State holds secrets in plain text (database endpoints, generated values):
# encrypted at rest, never public, owned by this account only.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = var.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = var.bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = var.bucket

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
