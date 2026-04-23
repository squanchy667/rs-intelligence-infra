# Deployment — first-time runbook

The order below is the happy path for a clean AWS account. AWS CLI configured
with profile `rs-intel`, region `eu-west-1`.

> ⚠ **This runbook stands up the STAGING environment.** It has intentional
> shortcuts (HTTP ALB, single-AZ RDS, legacy endpoints unauthenticated,
> `CORS_ALLOW_ORIGINS=*`). See
> [`PRODUCTION_CHECKLIST.md`](https://github.com/squanchy667/dara-v2-docs/blob/main/PRODUCTION_CHECKLIST.md)
> in the docs repo before any real traffic lands on this stack.

> 🧪 **After you finish this runbook**, work through [`SMOKE_TEST.md`](./SMOKE_TEST.md)
> to verify everything end-to-end. It covers auth, feature flags, report
> generation, CI round-trips, and the known negative cases.

## 1. Bootstrap the Terraform backend

Run **once** per AWS account (the S3 bucket + DynamoDB table referenced by
`main.tf` must exist before `terraform init` succeeds):

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

## 2. First `terraform apply` — everything except ECS

The ECS service (T060) won't start tasks until there's an image in ECR. We
apply everything up to and including the ECR repo in one pass, then push
the first image, then apply again to create ECS.

```sh
cd rs-intelligence-infra
terraform init
# Targeted apply: bring up networking + ECR + RDS + ALB + S3/CF + secrets
terraform apply -var-file=environments/staging/terraform.tfvars \
    -target=module.networking \
    -target=module.ecr \
    -target=module.database \
    -target=module.alb \
    -target=module.storage \
    -target=module.secrets
```

Expect ~15 min (most of it CloudFront).

## 3. Push the first API image

```sh
cd ../dara-v2

# Look up the ECR URL
REPO=$(cd ../rs-intelligence-infra && terraform output -raw ecr_repository_url)
REGISTRY=$(echo "$REPO" | cut -d/ -f1)

# Auth docker to ECR
aws ecr get-login-password --region eu-west-1 --profile rs-intel \
    | docker login --username AWS --password-stdin "$REGISTRY"

# Build + push
docker build -t rs-intelligence-api:staging .
docker tag rs-intelligence-api:staging "${REPO}:latest"
docker push "${REPO}:latest"
```

## 4. Full apply — brings up ECS

```sh
cd ../rs-intelligence-infra
terraform apply -var-file=environments/staging/terraform.tfvars
```

The ECS service pulls `:latest`, the ALB target group health-checks it on
`/api/health`, and CloudFront starts routing `/api/*` to the ALB.

## 5. Rotate the placeholder reCAPTCHA key

```sh
aws secretsmanager put-secret-value \
    --secret-id rs-intelligence/staging/nadlan-recaptcha-key \
    --secret-string "$RECAPTCHA_KEY" \
    --profile rs-intel --region eu-west-1
```

ECS containers pick it up on next task restart (or you can force a new
deployment: `aws ecs update-service --cluster rs-intelligence-staging --service rs-intelligence-staging-api --force-new-deployment`).

## 6. Seed the database

> **Schema is managed by Alembic.** The API container runs
> `alembic upgrade head` on startup via `docker-entrypoint.sh`, so on first
> boot RDS already has every table. You only need to load the data.

Data flow during the POC: **run `sync` locally** against the local Docker
PostgreSQL, export, then restore into RDS via ECS Exec.

```sh
# On your laptop, against local Docker DB
cd dara-v2
docker compose up -d postgres
python -m dara_v2 migrate            # alembic upgrade head
python -m dara_v2 sync --city חדרה
python -m dara_v2 sync --city ירושלים
python -m dara_v2 sync --city אופקים

python -m dara_v2 export-staging --cities "ירושלים,חדרה,אופקים"
# → staging-seed.sql.gz + staging-seed.manifest.json

# Upload to your seed bucket (create one first if you don't have one)
aws s3 cp staging-seed.sql.gz s3://<your-bucket>/staging-seed.sql.gz \
    --profile rs-intel
```

```sh
# Back in rs-intelligence-infra — grant the task role read access to your bucket
terraform apply -var-file=environments/staging/terraform.tfvars \
    -var 'seed_bucket_arn=arn:aws:s3:::<your-bucket>'
# (or wire the var through in terraform.tfvars)
```

```sh
# ECS Exec into a task
TASK=$(aws ecs list-tasks \
    --cluster rs-intelligence-staging \
    --service-name rs-intelligence-staging-api \
    --profile rs-intel --region eu-west-1 \
    --query 'taskArns[0]' --output text)

aws ecs execute-command \
    --cluster rs-intelligence-staging \
    --task "$TASK" --container api \
    --interactive --command "/bin/sh" \
    --profile rs-intel --region eu-west-1

# Inside the container:
python -m dara_v2 seed-staging --source s3://<your-bucket>/staging-seed.sql.gz
```

`seed-staging` runs `alembic upgrade head` first (idempotent — no-op if the
container entrypoint already ran it), then downloads + gunzips and applies
the INSERTs. The seed SQL wraps everything in `BEGIN`/`COMMIT` and resets
SERIAL sequences at the end — safe to re-run as you refresh the snapshot
weekly.

### Schema migrations going forward

```sh
# 1. Change a model in dara-v2/dara_v2/models.py
# 2. Autogenerate a migration against your local DB:
cd dara-v2
python -m dara_v2 migrate           # bring local to head first
alembic revision --autogenerate -m "add X column"
# Review the generated file in alembic/versions/, edit if needed, commit.

# 3. Push to main → CI builds + deploys → container entrypoint runs
#    `alembic upgrade head` at start → new schema is live.
# 4. (If the migration alters existing rows) re-export seed on your laptop
#    and re-run seed-staging.
```

To inspect the current RDS revision:

```sh
# Inside an ECS Exec shell
python -m dara_v2 db-current
# 0001 (head)
```

**Bypass migrations on container start** (for a diagnostic shell):

```sh
aws ecs run-task ... --overrides '{"containerOverrides":[{
    "name":"api",
    "environment":[{"name":"SKIP_MIGRATIONS","value":"1"}],
    "command":["/bin/sh"]
}]}'
```

## 7. Create the initial admin user

Still inside the ECS Exec shell:

```sh
python -m dara_v2 create-user \
    --email ofekaviv9@gmail.com \
    --password "$(openssl rand -base64 24)" \
    --name "Ofek Aviv" \
    --role admin
```

Record the password in a password manager — the CLI prints the email but
the password you supplied.

## 8. Smoke test

See the **[SMOKE_TEST.md](./SMOKE_TEST.md) runbook** — a 13-section
checklist covering health, auth, feature flags, data + reports, logs,
alarms, scheduled tasks, ECS Exec, CI/CD round-trip, and negative cases.

Quick sanity bite if you're in a hurry:

```sh
CF=$(terraform output -raw cloudfront_domain_name)
curl -sS "https://$CF/api/health" | jq .          # 200 with db=true, llm.ok=true

TOKEN=$(curl -sS -X POST "https://$CF/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d '{"email":"ofekaviv9@gmail.com","password":"<the-password>"}' \
    | jq -r .access_token)
curl -sS "https://$CF/api/auth/me" -H "Authorization: Bearer $TOKEN" | jq .
# expect: { id, email, name, role="admin" }
open "https://$CF"
```

## Ongoing: weekly data refresh

```sh
# Laptop
python -m dara_v2 sync --city <city>        # whichever cities changed
python -m dara_v2 export-staging --cities "ירושלים,חדרה,אופקים"
aws s3 cp staging-seed.sql.gz s3://<bucket>/staging-seed.sql.gz

# ECS Exec → inside container
python -m dara_v2 seed-staging --source s3://<bucket>/staging-seed.sql.gz
```

## When to bump the ECS service to 0.5 vCPU / 1 GB

- Scheduled sync (T065) isn't yet live, and you want to run `dara-v2 sync`
  via ECS Exec instead of locally — chromium inside the container can OOM
  at 0.5 GB
- You notice `OutOfMemory` in the CloudWatch log group
- You start running multiple concurrent report generations

Edit `environments/staging/terraform.tfvars`:

```hcl
ecs_task_cpu        = 512
ecs_task_memory_mib = 1024
```

(add these inputs through the root variable surface when needed)
