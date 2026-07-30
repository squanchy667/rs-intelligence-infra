**DO NOT APPLY — scaffold only; stg box is green-lit later; the cicd root
already carries stg's deploy role/activation.**

## What this is

An inert mirror of `environments/dev`'s root, retargeted to
`environment = "stg"` and state key `stg/terraform.tfstate`. Same
`../../modules/dev-box` instantiation shape, same variables, same outputs
— nothing new, nothing environment-specific beyond the name and the state
key.

It exists now so the shape is reviewed and ready, not because the stg box
is being stood up yet. `environments/cicd` already instantiates
`module.stg` (a `gha-deploy-env` — deploy role, SSM box role, SSM
activation) against this environment's `branch = "stg"`, so once this
root is applied and the box exists, the CI/CD side of stg is already
wired and waiting.

## When stg is green-lit

1. `terraform -chdir=environments/stg init`
2. `terraform -chdir=environments/stg apply` — creates the Lightsail box,
   static IP, key pair (same shape as `environments/dev`).
3. Register the box's SSM agent using `module.stg`'s activation
   id/code from `environments/cicd` (see that root's README runbook
   section) so GitHub Actions can reach it via `ssm:SendCommand`.
4. Wire a `stg` branch + deploy workflow (CI-2) pointed at this box.

Until step 1 happens, this directory is Terraform that validates and
formats cleanly but was never applied — treat it as a template, not a
resource.
