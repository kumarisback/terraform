# state-bucket

Hardens an existing Terraform state bucket (roadmap step 25, learning topic 25): versioning
(the state's own backup), a lifecycle that bounds the history, default encryption, no
public access, bucket-owner-enforced ownership. It manages settings only, never the bucket.
Used by `infrastructure/shared-services` for every bucket in `terraform_state_bucket_names`.

Not here, on purpose: a bucket policy (it would replace whatever policy the bucket has),
Object Lock and MFA delete (learning topic 25 says how and why to add them by hand).
