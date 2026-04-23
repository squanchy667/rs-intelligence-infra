############################################################################
# S3 + CloudFront — single distribution, dual origin
#
#   /*      → S3 (Next.js static export, OAC-restricted)
#   /api/*  → ALB (HTTP origin, no cache, auth headers forwarded)
#
# No custom domain: CloudFront's default *.cloudfront.net URL + cert.
############################################################################

locals {
  name        = "${var.project_name}-${var.environment}"
  bucket_name = "${local.name}-${var.bucket_name_suffix}"

  s3_origin_id  = "s3-frontend"
  alb_origin_id = "alb-api"
}

# ── S3 frontend bucket ────────────────────────────────────────────────

resource "aws_s3_bucket" "frontend" {
  bucket = local.bucket_name

  tags = { Name = local.bucket_name }
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── Origin Access Control — CloudFront signs S3 requests ─────────────

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── CloudFront distribution ──────────────────────────────────────────

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${local.name} — dual origin (S3 + ALB)"
  price_class         = var.price_class
  default_root_object = "index.html"

  # ── S3 origin ─────────────────────────────────────────────────────
  origin {
    origin_id                = local.s3_origin_id
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # ── ALB origin (HTTP only — CloudFront handles TLS) ───────────────
  origin {
    origin_id   = local.alb_origin_id
    domain_name = var.alb_dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # ── Default behavior — S3 ─────────────────────────────────────────
  default_cache_behavior {
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # CachingOptimized managed policy
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # ── /_next/static/* — long-cache hashed assets ────────────────────
  ordered_cache_behavior {
    path_pattern           = "/_next/static/*"
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # CachingOptimized — 1 year defaults, honors Cache-Control from S3
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # ── /api/* — ALB origin, cache disabled, forward everything ──────
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = local.alb_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # CachingDisabled managed policy
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    # AllViewer origin request policy — forwards all headers, query strings,
    # and cookies to the origin (needed for Authorization + JWT + search params).
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }

  # ── SPA routing — serve index.html for 403/404 so deep links work ─
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${local.name}-cdn" }
}

# ── S3 bucket policy — only this CloudFront distribution can read ────

data "aws_iam_policy_document" "s3_frontend" {
  statement {
    sid     = "AllowCloudFrontOACRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.s3_frontend.json
}
