# compute/ecr

ECR repository for the FastAPI Docker image.

**Task:** T053

## Resources

- `aws_ecr_repository.this` — name `rs-intelligence-api` (variable), AES256
  encryption, scan on push, tag mutability MUTABLE (so CI can overwrite
  `:latest`).
- `aws_ecr_lifecycle_policy.this`:
  1. Keep the last 5 tagged images — older ones expire.
  2. Expire untagged images 1 day after push.

## Variables

| Name | Default | Notes |
|------|---------|-------|
| `repository_name` | `rs-intelligence-api` | |
| `image_tag_mutability` | `MUTABLE` | tighten to `IMMUTABLE` for prod |
| `scan_on_push` | `true` | |
| `keep_last_tagged_images` | `5` | |
| `untagged_image_ttl_days` | `1` | |

## Outputs

`repository_name`, `repository_url`, `repository_arn`, `registry_id`.

## Manual push (smoke test)

```sh
aws ecr get-login-password --region eu-west-1 --profile rs-intel | \
    docker login --username AWS --password-stdin <registry_id>.dkr.ecr.eu-west-1.amazonaws.com

cd ../../../dara-v2
docker build -t rs-intelligence-api:smoke .
docker tag  rs-intelligence-api:smoke <repository_url>:smoke
docker push <repository_url>:smoke
```

CI/CD (T063) handles this automatically on push to `main`.
