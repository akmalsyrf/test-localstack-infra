resource "aws_s3_bucket" "this" {
  bucket = var.bucket
  tags   = var.tags

  # Fail fast under LocalStack/Docker contention instead of hanging to the job cutoff.
  timeouts {
    create = "3m"
    delete = "3m"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Suspended"
  }
}

# SSE-S3 (AES256) — AWS-owned key, no custom KMS (LocalStack free-tier safe).
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Expire noncurrent versions after 30 days when versioning is enabled.
# Skipped when versioning is off (lifecycle filter would be a no-op / noise).
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count  = var.versioning_enabled ? 1 : 0
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-noncurrent-30d"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}
