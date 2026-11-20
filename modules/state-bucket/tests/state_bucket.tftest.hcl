# terraform test (run in modules/state-bucket: terraform init && terraform
# test). The AWS provider is mocked: nothing created, nothing billed.
mock_provider "aws" {}

variables {
  bucket = "dev-602367507570-us-east-1-an"
}

run "versioned_private_encrypted" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled" &&
      aws_s3_bucket_public_access_block.this.restrict_public_buckets &&
      aws_s3_bucket_public_access_block.this.block_public_policy &&
      one(aws_s3_bucket_ownership_controls.this.rule).object_ownership == "BucketOwnerEnforced"
    )
    error_message = "State buckets are versioned, private and owner-enforced."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "SSE-S3 without a KMS key."
  }

  assert {
    condition = (
      one(one(aws_s3_bucket_lifecycle_configuration.this.rule).noncurrent_version_expiration).noncurrent_days == 90 &&
      one(one(aws_s3_bucket_lifecycle_configuration.this.rule).noncurrent_version_expiration).newer_noncurrent_versions == 20
    )
    error_message = "Older versions kept 90 days, the 20 newest always."
  }
}

run "kms_when_given" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:602367507570:key/0b1c2d3e-0000-0000-0000-000000000000"
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "aws:kms with a key."
  }
}

run "refuses_a_short_history" {
  command = plan

  variables {
    noncurrent_days = 7
  }

  expect_failures = [var.noncurrent_days]
}
