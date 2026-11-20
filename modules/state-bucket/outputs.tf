output "versioning_status" {
  description = "Enabled, once applied"
  value       = aws_s3_bucket_versioning.this.versioning_configuration[0].status
}
