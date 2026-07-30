project_name = "rs-intelligence"
aws_region   = "eu-west-1"
github_repo  = "squanchy667/dara-v2"

alert_email = "ofekaviv9@gmail.com"

# Confirmed 2026-07-30: account has NO existing trail (describe-trails empty),
# so the dedicated trail is required for the failed-AssumeRole alarm.
create_cloudtrail = true

# Leave empty unless ssm:resourceTag/DeployEnv propagation doesn't reach a
# box in practice — see modules/gha-deploy-env/README.md.
managed_instance_id_dev  = ""
managed_instance_id_test = ""
managed_instance_id_stg  = ""

# Null (unset) — AWS applies its own default activation window.
# ssm_activation_expiration = ""
