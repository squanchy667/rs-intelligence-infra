# cicd

GitHub Actions OIDC provider + two least-privilege deploy roles.

**Task:** T063 + T064 (the IAM half)

## What it creates

- `aws_iam_openid_connect_provider.github` — points at
  `token.actions.githubusercontent.com`. **Only one per AWS account.** If
  you re-apply into an account that already has it, import first:

  ```sh
  terraform import \
      module.cicd.aws_iam_openid_connect_provider.github \
      arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com
  ```

- `aws_iam_role.backend` — `<project>-<env>-github-backend`
  - Trust: `repo:<org>/<backend_repo>:ref:refs/heads/<deploy_branch>` (PR
    branches + forks can't assume it)
  - Perms: ECR push/pull on the `rs-intelligence-api` repo only,
    ECS UpdateService / RegisterTaskDefinition scoped to the cluster,
    PassRole on the two ECS-task roles

- `aws_iam_role.frontend` — `<project>-<env>-github-frontend`
  - Trust: `repo:<org>/<frontend_repo>:ref:refs/heads/<deploy_branch>`
  - Perms: S3 list + get/put/delete on the frontend bucket contents only,
    CreateInvalidation on the one distribution

## Wiring it to GitHub

After apply:

```sh
BACKEND_ROLE=$(terraform output -raw backend_github_role_arn)
FRONTEND_ROLE=$(terraform output -raw frontend_github_role_arn)

# Set secrets in each repo's `staging` environment:
gh secret set AWS_DEPLOY_ROLE_ARN \
    --repo squanchy667/dara-v2 \
    --env staging \
    --body "$BACKEND_ROLE"

gh secret set AWS_DEPLOY_ROLE_ARN \
    --repo squanchy667/dara-v2-ui \
    --env staging \
    --body "$FRONTEND_ROLE"
```

Also set the CloudFront distribution ID as a fallback for the frontend
workflow (primary lookup is the bucket tag):

```sh
CF_ID=$(terraform output -raw cloudfront_distribution_id)
gh secret set CLOUDFRONT_DISTRIBUTION_ID \
    --repo squanchy667/dara-v2-ui \
    --env staging \
    --body "$CF_ID"
```

## Variables

- `github_org` (default `squanchy667`)
- `backend_repo` (default `dara-v2`), `frontend_repo` (default `dara-v2-ui`)
- `deploy_branch` (default `main`) — change to `staging` if you'd rather
  have the workflows trigger off a `staging` branch instead of `main`
- ECR/ECS/S3/CloudFront ARNs wired in by the root module

## Security notes

- No long-lived AWS keys in GitHub secrets. Each workflow run gets a
  15-minute STS session bound to that specific job's OIDC claim.
- The `sub` condition pins both roles to a specific branch ref. A
  collaborator pushing a PR can't roll the prod service; they'd have to
  merge to `main` (or whichever `deploy_branch` is set).
- If you ever need a second env (prod), fork this module into a separate
  instantiation with different role names.
