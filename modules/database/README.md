# database

PostgreSQL 16 RDS instance, private-subnet, free-tier-eligible.

**Task:** T056

## Resources

- `aws_db_subnet_group.this` — private subnets (from networking module)
- `aws_db_parameter_group.this` — postgres16 family,
  `shared_preload_libraries=pg_stat_statements`,
  `log_min_duration_statement=1000` (slow-query threshold 1 s)
- `aws_db_instance.this`:
  - `db.t4g.micro`, 20 GB gp3 (autoscale to 100 GB), storage encrypted
  - `publicly_accessible=false`, `multi_az=false` (staging)
  - backup 7-day retention, 03:00-04:00 UTC window
  - `deletion_protection=false`, `skip_final_snapshot=true` — easy teardown
  - `enabled_cloudwatch_logs_exports=["postgresql"]`

## Variables

`private_subnet_ids`, `security_group_id`, `master_password` (from secrets
module), plus a bunch of defaults that mirror local Docker (`dara_v2` db,
`dara` user, postgres 16.4).

## Outputs

`endpoint` (host:port — `DATABASE_URL`), `address`, `port`, `database_name`,
`master_username`, `identifier`, `arn`.

## Connecting from local (debugging)

Because RDS is private-only, the only inroad is via an ECS Exec shell:

```sh
aws ecs execute-command \
    --cluster rs-intelligence-staging \
    --task <task-arn> --container api \
    --interactive --command "/bin/sh" \
    --profile rs-intel --region eu-west-1

# inside the container:
psql "$DATABASE_URL"
```
