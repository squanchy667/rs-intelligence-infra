project_name = "rs-intelligence"
environment  = "staging"
aws_region   = "eu-west-1"
alert_email  = "ofekaviv9@gmail.com"

# T062 staging seed bucket. Holds staging-seed.sql.gz exported from the
# operator's laptop and pulled by `dara-v2 seed-staging` via ECS Exec.
seed_bucket_arn = "arn:aws:s3:::rs-intelligence-staging-seed-502140064073"
