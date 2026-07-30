# ── Shared CI/CD artifact bucket ────────────────────────────────────────
#
# GitHub Actions build artifacts (bundle.tar.gz per deploy) land under
# <env>/<sha>/bundle.tar.gz. One bucket shared by all three environments;
# each gha-deploy-env role is IAM-scoped to its own <env>/* prefix only —
# see modules/gha-deploy-env.

resource "aws_s3_bucket" "artifacts" {
  bucket = "rs-intelligence-cicd-artifacts-${data.aws_caller_identity.current.account_id}"

  tags = { Name = "rs-intelligence-cicd-artifacts" }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 60-day expiration is the ratified keep-last-10 approximation — normal
# deploy cadence keeps well over 10 artifacts per env inside a 60-day
# window. Rolling back to something older than that means rebuilding from
# the git tag instead of replaying a stored artifact.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  dynamic "rule" {
    for_each = toset(["dev", "test", "stg"])
    content {
      id     = "expire-${rule.value}"
      status = "Enabled"

      filter {
        prefix = "${rule.value}/"
      }

      expiration {
        days = 60
      }

      noncurrent_version_expiration {
        noncurrent_days = 7
      }
    }
  }

  rule {
    id     = "abort-incomplete-multipart-upload"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
