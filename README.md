# rs-intelligence-infra

Terraform infrastructure for the **RS Intelligence** staging deployment (AWS,
`eu-west-1`).

## Layout

```
.
├── main.tf                  # Provider + S3 remote backend config
├── variables.tf             # Root input variables
├── outputs.tf               # Aggregated outputs
├── versions.tf              # Terraform + provider version pins
├── environments/
│   └── staging/
│       └── terraform.tfvars # Staging values
└── modules/
    ├── networking/          # T052 — VPC, subnets, SGs
    ├── database/            # T056 — RDS PostgreSQL
    ├── compute/             # T057, T060 — ALB, ECS Fargate
    ├── storage/             # T058 — S3 + CloudFront (dual origin)
    ├── secrets/             # T059 — Secrets Manager
    └── scheduling/          # T065 — EventBridge cron
```

## First-time setup

The S3 backend referenced in `main.tf` must exist before `terraform init`
succeeds. Bootstrap it once with the AWS CLI:

```sh
aws s3 mb s3://rs-intelligence-terraform-state --region eu-west-1
aws s3api put-bucket-versioning \
    --bucket rs-intelligence-terraform-state \
    --versioning-configuration Status=Enabled
aws s3api put-public-access-block \
    --bucket rs-intelligence-terraform-state \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws dynamodb create-table \
    --table-name rs-intelligence-terraform-lock \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region eu-west-1
```

Requires AWS CLI configured with a profile that has write access to S3 and
DynamoDB in `eu-west-1`. For this project use the `rs-intel` profile:

```sh
export AWS_PROFILE=rs-intel
```

## Usage

```sh
terraform init
terraform plan  -var-file=environments/staging/terraform.tfvars
terraform apply -var-file=environments/staging/terraform.tfvars
```

## Architecture (target, across Phase 7 tasks)

```
CloudFront (automatic HTTPS, default *.cloudfront.net URL)
  ├── /*     → S3 (Next.js static export)      [T058]
  └── /api/* → ALB (HTTP) → ECS Fargate (FastAPI)   [T057, T060]
                              ├── RDS PostgreSQL (private subnet) [T056]
                              ├── Secrets Manager                 [T059]
                              └── Bedrock Claude 3.5 (optional)
```

## Task map

| Task | Module / File | Status |
|------|---------------|--------|
| T045 | Root + backend + module skeleton | ✅ this commit |
| T052 | modules/networking | pending |
| T053 | modules/compute (ECR) | pending |
| T056 | modules/database | pending |
| T057 | modules/compute (ALB) | pending |
| T058 | modules/storage | pending |
| T059 | modules/secrets | pending |
| T060 | modules/compute (ECS) | pending |
| T065 | modules/scheduling | pending |
