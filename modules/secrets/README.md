# secrets

AWS Secrets Manager entries for `rs-intelligence-<env>` + an IAM policy doc
that the ECS task role (T060) attaches.

**Task:** T059

## What it creates

| Name | Value | Consumed by |
|------|-------|-------------|
| `rs-intelligence/<env>/rds-password` | `random_password` (32 chars, RDS-safe symbols) | RDS (T056), ECS task def (T060) |
| `rs-intelligence/<env>/jwt-secret` | `random_password` (64 chars, alphanumeric) | FastAPI auth middleware |
| `rs-intelligence/<env>/nadlan-recaptcha-key` | placeholder, `ignore_changes` on the version | nadlan collector |

`recovery_window_in_days = 0` for staging (immediate deletion on destroy).

## Rotating the nadlan reCAPTCHA key

The Terraform resource only seeds a placeholder so the secret exists with a
version. The real key is rotated in out-of-band:

```sh
aws secretsmanager put-secret-value \
    --secret-id rs-intelligence/staging/nadlan-recaptcha-key \
    --secret-string "$(pbpaste)" \
    --profile rs-intel --region eu-west-1
```

The module has `lifecycle { ignore_changes = [secret_string] }` on that
version, so subsequent `terraform apply`s won't overwrite your value.

## Outputs

- `rds_password_secret_arn`, `rds_password` (sensitive) — RDS needs both
  the ARN (for ECS env-from-secret wiring) and the plaintext (to set
  `aws_db_instance.password`).
- `jwt_secret_arn`, `nadlan_recaptcha_key_secret_arn`
- `ecs_read_policy_json` — attach this to the ECS task role in T060.
