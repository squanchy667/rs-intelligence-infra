# compute/ecs

ECS Fargate cluster + `api` service running the FastAPI backend.

**Task:** T060

## What it creates

- `aws_secretsmanager_secret.database_url` — composed `postgresql://` URL,
  kept alongside the other rs-intelligence secrets so the ECS task def can
  inject `DATABASE_URL` as a single env var
- `aws_cloudwatch_log_group.api` — `/ecs/<project>-<env>`, 14-day retention
- `aws_ecs_cluster.this` + capacity-provider strategy (Fargate)
- Two IAM roles:
  - **task-exec** — managed `AmazonECSTaskExecutionRolePolicy` + inline
    `secretsmanager:GetSecretValue` on the four specific ARNs (JWT, reCAPTCHA,
    RDS password, DATABASE_URL)
  - **task** — `bedrock:InvokeModel` on the two Claude ARNs, plus the
    SSM-channel perms for ECS Exec, plus read on the three ambient secrets,
    plus optional `s3:GetObject` on `seed_bucket_arn` when provided
- `aws_ecs_task_definition.api` — 0.25 vCPU / 512 MB, container runs
  `uvicorn dara_v2.api:app` from `${ecr_url}:${image_tag}`, env vars for
  feature flags + LLM config, secrets injection for DATABASE_URL / JWT_SECRET
  / NADLAN_RECAPTCHA_KEY, container-level `/api/health` healthcheck
- `aws_ecs_service.api` — 1 desired task, attached to ALB target group,
  awsvpc in private subnets, ECS Exec enabled, `ignore_changes` on
  `task_definition` + `desired_count` so CI deploys aren't reverted by
  subsequent terraform apply runs

## Resource sizing — current assumptions

**0.25 vCPU / 512 MB** is adequate for the API-only workload:

- FastAPI + psycopg2 + stdlib uses ~150-200 MB at idle, ~300 MB under light
  load
- Data updates happen **from the operator's laptop** during the POC
  (`dara-v2 sync` on local → `dara-v2 export-staging` → upload seed →
  `dara-v2 seed-staging` via ECS Exec). Chromium is never spawned inside
  the live API container under this flow.

**Future bump** — when scheduled sync lands (T065, EventBridge cron running
an ECS RunTask), give that task its own sizing (e.g., `1 vCPU / 2 GB`)
and leave the API service at 0.25/0.5. Only bump the API if you start
running heavy CLI work inside it via ECS Exec.

## First deploy

ECS will fail to start tasks if the ECR repo is empty. You push the first
image manually, then `terraform apply`:

```sh
# From inside the dara-v2 repo
aws ecr get-login-password --region eu-west-1 --profile rs-intel | \
    docker login --username AWS --password-stdin \
    <account-id>.dkr.ecr.eu-west-1.amazonaws.com

docker build -t rs-intelligence-api:staging .
docker tag rs-intelligence-api:staging \
    <ecr_url>:latest
docker push <ecr_url>:latest

# Back in rs-intelligence-infra
terraform apply -var-file=environments/staging/terraform.tfvars
```

After the first deploy, CI/CD (T063) takes over and overwrites `:latest`
on every push to `main`.

## ECS Exec recipe

```sh
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
python -m dara_v2 create-user --email ... --password ... --name ... --role admin
python -m dara_v2 seed-staging --source s3://your-bucket/staging-seed.sql.gz
```

## Inputs

All the cross-module outputs (networking, ALB, ECR, secrets, database) plus
the sizing + config knobs documented in `variables.tf`. The notable ones:

- `image_tag` (default `latest`)
- `task_cpu` / `task_memory_mib` (256 / 512)
- `feature_flags` (object; all four false by default for staging)
- `seed_bucket_arn` (optional; grants S3 GetObject on the bucket for T062)

## Outputs

- `cluster_name`, `cluster_arn`
- `service_name`
- `task_definition_arn`, `task_definition_family` (CI uses the family)
- `task_execution_role_arn`, `task_role_arn`
- `log_group_name`
- `database_url_secret_arn`
