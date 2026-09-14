**Apply on the CEO's word only** (STG Phase 2 of
`DaraReports/plans/PLAN_STG_STANDUP_2026-09-14.md`). Not applied as of
2026-09-14: no `stg/terraform.tfstate` object exists yet. Until the word is
given this root is reviewed Terraform that validates and formats cleanly.

## What this is

The Lightsail box for **stg** — the team-demo twin of `test`
(`https://stg.rs-intel.com`, code ff'd `test → stg`, same blessed dump,
same Profile B levers). It mirrors `environments/dev`'s root exactly:
`../../modules/dev-box`, `environment = "stg"`, state key
`stg/terraform.tfstate`, the same variables (including `instance_name` for
a future snapshot-based resize) and the same outputs. Size is
**`small_3_0`** (2 GB, ~$12/mo dualstack) in `terraform.tfvars` — never
micro; box RAM was the first bottleneck on the 1 GB micros.

`environments/cicd` **is applied** (contrary to its older wording): it
already holds `module.stg` — the GitHub Actions deploy role
`rs-intelligence-gha-deploy-stg` (trust bound to `refs/heads/stg`, SSM
send scoped by the `DeployEnv=stg` tag), the box role and the SSM hybrid
activation. `AWS_ROLE_STG` is already a repo variable in
`squanchy667/dara-v2`. **The stg activation has expired** (minted
2026-08-03 with AWS's default 24 h window, 0 of 1 registrations used) —
replacing it is step 1 below, before the box can register.

## When the word is given (order matters)

1. cicd, activation only: `terraform -chdir=environments/cicd plan
   -replace='module.stg.aws_ssm_activation.this'` → expect **1 add / 0
   change / 1 destroy** → apply → `terraform -chdir=environments/cicd
   output -json | jq '.stg_activation_id.value, .stg_activation_code.value'`
   (the 24 h window starts now; register the same day).
2. `terraform -chdir=environments/stg init` (already init'd once on
   2026-07-30; harmless to repeat).
3. `terraform -chdir=environments/stg plan` → expect **~5 add / 0 change /
   0 destroy**, every resource named `rs-intelligence-stg-*` (key pair,
   instance, static IP, attachment, public ports). Anything else is the
   wrong directory.
4. `terraform -chdir=environments/stg apply`; then
   `terraform -chdir=environments/stg output -raw static_ip` and
   `output -raw private_key_pem > stg_box_key.pem && chmod 600 stg_box_key.pem`
   (`*.pem` is gitignored).
5. **DNS before the first `docker compose up`**: GoDaddy A `stg` → the
   static IP (TTL 600), proven by `dig +short A stg.rs-intel.com
   @ns47.domaincontrol.com` and `@8.8.8.8` (DEV.md "URL / DNS" hard gate;
   `dara-v2/deploy/CUTOVER_RUNBOOK_CI-3.md` §2). No sslip alias for stg.
6. Register the box's SSM agent with the step-1 id/code (runbook:
   `environments/cicd/README.md`), confirm the `DeployEnv=stg` tag, set
   `STG_INSTANCE_ID` + `STG_HOST=stg.rs-intel.com` in the dara-v2 repo
   variables.
7. Bootstrap the box (Phase 3 of the plan: 2 GB swapfile, `/opt/dara/.env`,
   postgres-only seed from the blessed dump + offline 0049, census), create
   the `stg` branches from test's green tip in **both** repos while
   `STG_ENABLED=false`, then `STG_ENABLED=true` **last** and dispatch
   `Deploy — stg` from the `stg` branch.
