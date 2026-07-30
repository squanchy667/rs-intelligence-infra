# gha-deploy-env

Per-environment building block for the GitHub Actions CI/CD deploy ladder
(`environments/cicd` instantiates this once each for dev, test, and stg).

## What it makes

- **`aws_iam_role.gha_deploy`** (`<project>-gha-deploy-<env_name>`) —
  assumed by GitHub Actions over OIDC. Trust policy accepts exactly one
  sub claim, ref-form only: `repo:<github_repo>:ref:refs/heads/<branch>`.
  No environment-form, no wildcards — a workflow run on any other branch,
  or from a fork, cannot assume it. Permissions: put/get objects under its
  own `<env_name>/*` prefix in the shared artifact bucket, list that prefix,
  `ssm:SendCommand` on the shared deploy document + this env's managed
  instance(s), and `ssm:GetCommandInvocation` to poll the result.
- **`aws_iam_role.ssm_box`** (`<project>-ssm-box-<env_name>`) — assumed by
  the SSM agent running on the Lightsail box. `AmazonSSMManagedInstanceCore`
  (AWS managed policy) plus an inline policy for CloudWatch Logs write, so
  `aws:runShellScript` output lands in the shared log group.
- **`aws_ssm_activation.this`** — the code/id pair used to register this
  environment's box as a hybrid (`mi-*`) managed node. `registration_limit
  = 1` (one box per env); tagged `DeployEnv = <env_name>`.

## Why hybrid activations

Lightsail instances have no IAM instance-profile attachment mechanism, so
they can never appear as ordinary EC2 managed nodes. AWS's hybrid/on-prem
activation flow is the documented workaround: mint an activation
(code + id), run the SSM agent's `-register` flag on the box with that
pair, and it shows up in Systems Manager as an `mi-*` managed node with
the IAM role attached to the activation.

## Tag-propagation is the IAM condition backbone

The `SsmSendInstance` statement is scoped to
`arn:aws:ssm:<region>:<account>:managed-instance/*` gated by a
`ssm:resourceTag/DeployEnv = <env_name>` condition (the default path,
`managed_instance_id = ""`). This works because tags applied to the
*activation* propagate to every managed node registered through it — see
[Tag a managed node registered with a hybrid or on-premises
activation](https://docs.aws.amazon.com/systems-manager/latest/userguide/hybrid-multicloud-managed-nodes-tags.html).
If that propagation doesn't hold in practice for some AWS account/region
combination, fall back to pinning the exact node instead (below).

## managed_instance_id fallback procedure

1. Register the box (see `environments/cicd/README.md` for the full
   `-register` command using this module's `activation_id` /
   `activation_code` outputs).
2. Verify the tag actually landed on the managed node:
   ```
   aws ssm list-tags-for-resource \
     --resource-type ManagedInstance \
     --resource-id mi-xxxxxxxxxxxxxxxxx \
     --region eu-west-1
   ```
3. If `DeployEnv` is present with the expected value, you're done — the
   default wildcard-plus-tag-condition scoping already covers this node.
4. If the tag is absent (or the account's tag-propagation behaves
   differently than documented), set `managed_instance_id = "mi-xxxx..."`
   in the env's tfvars for this environment and re-apply. The
   `SsmSendInstance` statement then targets that exact ARN instead of the
   tag-gated wildcard, with no condition at all.

## Inputs / outputs

See `variables.tf` / `outputs.tf`. Notably: this module takes
`account_id` and `aws_region` as plain variables rather than doing its own
`data "aws_caller_identity"` / region lookup — the root (`environments/cicd`)
looks those up once and passes them to all three instantiations.
