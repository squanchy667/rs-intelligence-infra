output "bucket_name" {
  value       = aws_s3_bucket.frontend.bucket
  description = "S3 bucket hosting the Next.js static build."
}

output "bucket_arn" {
  value       = aws_s3_bucket.frontend.arn
  description = "S3 bucket ARN."
}

output "bucket_regional_domain_name" {
  value       = aws_s3_bucket.frontend.bucket_regional_domain_name
  description = "S3 regional endpoint (used as CloudFront origin)."
}

output "cloudfront_distribution_id" {
  value       = aws_cloudfront_distribution.this.id
  description = "CloudFront distribution ID (used by CI cache invalidations)."
}

output "cloudfront_distribution_arn" {
  value       = aws_cloudfront_distribution.this.arn
  description = "CloudFront distribution ARN."
}

output "cloudfront_domain_name" {
  value       = aws_cloudfront_distribution.this.domain_name
  description = "CloudFront default domain — *.cloudfront.net. This is the public URL for both frontend and /api/*."
}
