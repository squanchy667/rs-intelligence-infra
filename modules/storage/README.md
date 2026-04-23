# storage

Single CloudFront distribution with **dual origin** (S3 + ALB) serving both
the Next.js static frontend and the FastAPI backend under one URL.

**Task:** T058

## Architecture

```
User ── HTTPS ──► CloudFront (*.cloudfront.net, default cert)
                    │
                    ├─ /*              → S3 (OAC, static export)
                    ├─ /_next/static/* → S3 (long-cache managed policy)
                    └─ /api/*          → ALB (HTTP, cache disabled, all headers forwarded)
```

## Resources

### S3

- `aws_s3_bucket.frontend` — name `<project>-<env>-frontend`
- Versioning **enabled** (rollback safety)
- Public access **blocked** (OAC only)
- `AES256` SSE default

### CloudFront

- `aws_cloudfront_origin_access_control.frontend` — sigv4, signs S3 requests
- `aws_cloudfront_distribution.this`:
  - Default behavior: S3 origin, CachingOptimized managed policy
    (`658327ea-f89d-4fab-a63d-7e88639e58f6`)
  - `/_next/static/*`: S3, same CachingOptimized policy
  - `/api/*`: ALB origin (HTTP only, TLSv1.2 if origin goes HTTPS later),
    CachingDisabled managed policy (`4135ea2d-6df8-44a3-9df3-4b5a84be39ad`)
    + AllViewer origin request policy (`216adef6-5c7f-47e4-b989-5492eafa07d3`)
    so `Authorization` headers, cookies, and query strings reach the API
  - `price_class = PriceClass_100` — cheapest (US/CA/Europe)
  - `default_root_object = index.html`
  - Custom error responses: 403/404 → `/index.html` (200) for SPA deep links

### S3 bucket policy

Allows `s3:GetObject` only from the specific CloudFront distribution ARN
(`AWS:SourceArn` condition) — nothing else, including the AWS console, can
download objects directly.

## Outputs

`bucket_name`, `bucket_arn`, `cloudfront_distribution_id`,
`cloudfront_distribution_arn`, `cloudfront_domain_name`.

## Why dual origin (instead of separate subdomains)

- **No CORS** — frontend uses relative `/api/` URLs, same origin as JS
- **One URL** to share with testers, one HTTPS cert to worry about (zero,
  actually — CloudFront default cert covers `*.cloudfront.net`)
- **Matches production pattern** — if we later add a custom domain it slides
  into the distribution without frontend changes

## First deploy

1. `terraform apply` — creates bucket + distribution (~15 min for the CDN
   to propagate)
2. Frontend CI (T064) `npm run build && aws s3 sync out/ s3://<bucket>`
3. `aws cloudfront create-invalidation --distribution-id ... --paths '/*'`
