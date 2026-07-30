# ── CloudTrail (optional; var-gated) ────────────────────────────────────
#
# The failed-AssumeRole EventBridge rule below only sees
# AssumeRoleWithWebIdentity events while a CloudTrail trail logging
# management events exists somewhere in the account. If the account
# already has one (e.g. an org-wide trail), set create_cloudtrail = false
# and skip standing up a second one — Ofek confirms which applies at
# apply time.
resource "aws_cloudtrail" "cicd" {
  count = var.create_cloudtrail ? 1 : 0

  name                          = "rs-intelligence-cicd-trail"
  s3_bucket_name                = aws_s3_bucket.trail[0].id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  # Management events only — no data events (S3/Lambda object-level
  # logging), which is what would otherwise dominate volume/cost here.
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  tags = { Name = "rs-intelligence-cicd-trail" }

  depends_on = [aws_s3_bucket_policy.trail]
}

resource "aws_s3_bucket" "trail" {
  count  = var.create_cloudtrail ? 1 : 0
  bucket = "rs-intelligence-cicd-trail-${data.aws_caller_identity.current.account_id}"

  tags = { Name = "rs-intelligence-cicd-trail" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  count  = var.create_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count                   = var.create_cloudtrail ? 1 : 0
  bucket                  = aws_s3_bucket.trail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  count  = var.create_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

# Bucket policy allowing the CloudTrail service to write — statement shape
# per AWS's documented example:
# https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html
data "aws_iam_policy_document" "trail_bucket" {
  count = var.create_cloudtrail ? 1 : 0

  statement {
    sid       = "AWSCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail[0].arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid       = "AWSCloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  count  = var.create_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  policy = data.aws_iam_policy_document.trail_bucket[0].json
}

# ── Failed-AssumeRole alarm (always on) ─────────────────────────────────
#
# Fires when GitHub Actions — or anyone — fails to assume one of the three
# gha-deploy roles via AssumeRoleWithWebIdentity: a stale/renamed branch, a
# forked PR probing for creds, a misconfigured workflow, etc. Only fires
# while a trail logging management events exists in the account (see
# create_cloudtrail above) — EventBridge sees CloudTrail-sourced events,
# not the API calls directly.
resource "aws_cloudwatch_event_rule" "failed_assume_role" {
  name        = "rs-intelligence-cicd-failed-assume-role"
  description = "AssumeRoleWithWebIdentity failures against the gha-deploy dev/test/stg roles."

  event_pattern = jsonencode({
    source      = ["aws.sts"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["AssumeRoleWithWebIdentity"]
      errorCode = [{ exists = true }]
      requestParameters = {
        roleArn = [
          module.dev.deploy_role_arn,
          module.test.deploy_role_arn,
          module.stg.deploy_role_arn,
        ]
      }
    }
  })

  tags = { Name = "rs-intelligence-cicd-failed-assume-role" }
}

resource "aws_sns_topic" "alerts" {
  name = "rs-intelligence-cicd-alerts"

  tags = { Name = "rs-intelligence-cicd-alerts" }
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "AllowEventBridgePublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

resource "aws_cloudwatch_event_target" "failed_assume_role_to_sns" {
  rule      = aws_cloudwatch_event_rule.failed_assume_role.name
  target_id = "cicd-alerts-sns"
  arn       = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_subscription" "alert_email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
