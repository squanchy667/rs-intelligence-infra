# environments/cicd

**NOT APPLIED YET** — this root exists in the repo as reviewed Terraform,
but `terraform apply` here is Ofek's activation step, not something to run
as part of building it out.

## What this root owns

The AWS-side plumbing for the GitHub Actions deploy ladder (`dev` → `test`
→ `stg`), shared across all three environments:

- **Three `module.dev` / `module.test` / `module.stg`** instances of
  `../../modules/gha-deploy-env` — each env's GitHub Actions OIDC deploy
  role, SSM box role, and SSM hybrid activation. See that module's README
  for what each instance makes.
- **`aws_s3_bucket.artifacts`** (`rs-intelligence-cicd-artifacts-<account>`)
  — shared build-artifact bucket, prefix-scoped per env, 60-day lifecycle
  expiry.
- **`aws_ssm_document.gha_deploy`** (`rs-intelligence-gha-deploy`) — the
  one shared deploy script every environment's `ssm:SendCommand` targets;
  behavior varies only by the parameters passed in.
- **`aws_cloudwatch_log_group.deploy`** (`/rs-intelligence/cicd/deploy`) —
  SSM command output, 90-day retention.
- **CloudTrail + EventBridge + SNS** — an optional dedicated trail
  (`var.create_cloudtrail`) feeding an always-on EventBridge rule that
  alarms on failed `AssumeRoleWithWebIdentity` calls against any of the
  three deploy roles.

It does **not** own the dev/dev2/stg Lightsail boxes themselves — those
stay in their own `environments/*` roots. This root only grants the IAM
+ artifact + document + logging plumbing that lets GitHub Actions reach
those boxes over SSM.

## Why `data "aws_iam_openid_connect_provider"` instead of a resource

The GitHub Actions OIDC provider is a singleton per AWS account.
`modules/cicd` already created it against the staging stack's state. A
second `resource "aws_iam_openid_connect_provider"` here would fail at
apply with `EntityAlreadyExists`. This root looks it up by URL instead.

## Runbook

### First apply

```
terraform -chdir=environments/cicd init
terraform -chdir=environments/cicd plan
terraform -chdir=environments/cicd apply
```

### Read the activation codes

```
terraform -chdir=environments/cicd output -json | \
  jq '{dev: {id: .dev_activation_id.value, code: .dev_activation_code.value},
       test: {id: .test_activation_id.value, code: .test_activation_code.value},
       stg: {id: .stg_activation_id.value, code: .stg_activation_code.value}}'
```

(`activation_code` is a sensitive output — `terraform output` alone masks
it; `-json` is required to read the real value.)

### Register a box's SSM agent (hybrid activation)

Run on the box itself, as root, after copying the id/code from above:

```
sudo systemctl stop amazon-ssm-agent
sudo /snap/amazon-ssm-agent/current/amazon-ssm-agent \
  -register -code <activation_code> -id <activation_id> -region eu-west-1 -y
sudo systemctl start amazon-ssm-agent
```

### Verify registration

```
aws ssm describe-instance-information --region eu-west-1
aws ssm list-tags-for-resource \
  --resource-type ManagedInstance --resource-id mi-xxxxxxxxxxxxxxxxx \
  --region eu-west-1
```

Confirm the `DeployEnv` tag is present with the expected value — that's
what the deploy role's `SsmSendInstance` condition matches against. If
it's missing, see `modules/gha-deploy-env/README.md`'s
`managed_instance_id` fallback procedure.

### Re-create an expired activation

Registration windows aren't indefinite. If a box's activation has expired
and it needs to (re-)register, replace just that activation resource
(the real address, not a guess — confirm with `terraform state list` if
module internals ever change):

```
terraform -chdir=environments/cicd apply \
  -replace='module.dev.aws_ssm_activation.this'
```

Then repeat the box-side registration command above with the new
id/code.

## Var-gated CloudTrail

`create_cloudtrail = true` (default) stands up a dedicated trail + its own
S3 bucket. If the account already has a trail logging management events
(e.g. an org-wide one), set `create_cloudtrail = false` in
`terraform.tfvars` instead of paying for + running a redundant one — Ofek
confirms which applies before the first apply.

## Alert email

`alert_email` defaults to `""` — the SNS topic and EventBridge wiring
exist either way, but no one is subscribed until it's set. Uncomment the
line in `terraform.tfvars` and re-apply once Ofek picks an address; SNS
email subscriptions require confirming a link AWS sends on first
subscribe.
