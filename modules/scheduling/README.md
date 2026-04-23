# scheduling

EventBridge rules that fire ECS RunTask on a cron, reusing the API task
definition with an overridden container command.

**Task:** T065

## Schedules

| Rule | Cron (UTC) | Israel time | Override command | Default |
|------|------------|-------------|------------------|---------|
| daily-sync | `cron(0 3 * * ? *)` | 06:00 IST | `python -m dara_v2 sync --all` | enabled |
| weekly-report | `cron(0 5 ? * SUN *)` | 08:00 Sunday | `python -m dara_v2 report --all-cities` | **disabled** |

## Toggling

Flip either in `environments/staging/terraform.tfvars`:

```hcl
scheduling_enable_daily_sync    = false  # using the manual laptop-sync loop
scheduling_enable_weekly_report = true   # opt in when you're ready
```

## How the override works

The rule's `input` field is a JSON document with a `containerOverrides` array.
EventBridge merges this into the task definition at RunTask time — only the
`command` is replaced, everything else (image, env vars, secrets, log config,
IAM, network) is inherited from the API task def. That means:

- A new CI image deploy instantly applies to the next scheduled run; no
  second redeploy for the cron
- Any new env var added to `module.ecs` is picked up automatically
- CloudWatch logs land in `/ecs/<project>-<env>` alongside the API logs —
  filter by `awslogs-stream-prefix=api` and by task ID

## IAM

Single role (`<project>-<env>-scheduler`) trusted by `events.amazonaws.com`:

- `ecs:RunTask` on the task definition family (wildcarded revision) + a
  `ecs:cluster ArnEquals` condition so it can't target another cluster
- `iam:PassRole` on the task-exec role AND the task role (ECS pulls both
  when launching a task)

## Operator-facing checks

```sh
# Manually invoke the daily sync right now
aws events put-events \
    --entries Source=manual.trigger,DetailType=manual-sync,Detail='{}'

# Or force a one-off RunTask with the same overrides:
aws ecs run-task \
    --cluster rs-intelligence-staging \
    --task-definition rs-intelligence-staging-api \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[...],securityGroups=[...]}" \
    --overrides '{"containerOverrides":[{"name":"api","command":["python","-m","dara_v2","sync","--all"]}]}'
```

## Why the POC starts with enable_daily_sync=true

The operator's current plan is **manual laptop-side syncs** — meaning the
cron adds no value day-to-day. It's enabled anyway because:

1. It's free to leave ticking (EventBridge + ECS RunTask only charge on
   actual invocation; a failing task still costs cents)
2. It exercises the scheduled-sync code path daily, surfacing regressions
   early (image breaks, IAM drifts, RDS creds rotated, etc.)
3. When you're ready to stop the manual loop, there's nothing to deploy —
   you just stop uploading fresh seeds

If you'd rather save the ~$1/month: flip `enable_daily_sync=false`.
