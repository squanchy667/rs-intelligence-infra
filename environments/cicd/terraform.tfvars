project_name = "rs-intelligence"
aws_region   = "eu-west-1"
github_repo  = "squanchy667/dara-v2"

# Set once Ofek picks an address, then re-apply to create the subscription.
# alert_email = "ofekaviv9@gmail.com"

create_cloudtrail = true

# Leave empty unless ssm:resourceTag/DeployEnv propagation doesn't reach a
# box in practice — see modules/gha-deploy-env/README.md.
managed_instance_id_dev  = ""
managed_instance_id_test = ""
managed_instance_id_stg  = ""

# Null (unset) — AWS applies its own default activation window.
# ssm_activation_expiration = ""
