# monitoring

SNS topic + email subscription + two CloudWatch alarms covering the backend.

**Task:** T066 (infra half)

## Alarms

| Name | Metric | Threshold | Window | When it fires |
|------|--------|-----------|--------|----------------|
| `alb-unhealthy-host` | `AWS/ApplicationELB:UnHealthyHostCount` | `> 0` | 5 × 1-min | Task is up but `/api/health` keeps returning non-200 |
| `ecs-no-running-task` | `ECS/ContainerInsights:RunningTaskCount` | `< 1` | 5 × 1-min | Service can't keep even one task up |

Both publish to the same SNS topic. `ok_actions` are also wired so you get a
recovery email when things go green again.

## Email confirmation

`aws_sns_topic_subscription` with `protocol = "email"` is fire-and-forget
on Terraform's side. AWS sends a confirmation link to `alert_email` the
first time you apply. Click it (from anywhere — no VPC access needed) and
the subscription transitions from `PendingConfirmation` to `Confirmed`.

Until confirmed, alarms still fire in CloudWatch but nothing lands in your
inbox.

## Caveat on `ECS/ContainerInsights`

`RunningTaskCount` is published to the `ECS/ContainerInsights` namespace
only when **Container Insights is enabled on the cluster**. T060 sets it
to `disabled` (free-tier cost avoidance). Options:

1. Flip `containerInsights = "enabled"` on the cluster — ~$0.30 per task
   per month in this namespace; minor.
2. Switch the metric to `AWS/ECS:CPUUtilization` with a 0% threshold (a
   stopped service reports nothing, which `treat_missing_data=breaching`
   turns into an alarm).
3. Or drop the second alarm — the ALB-unhealthy one already catches
   "service is broken" for practical purposes.

The module is wired assuming option 1 will be flipped when it matters.
If you leave Container Insights off, treat the ECS alarm as decorative
until then.

## Future alarms that plug in here

- Bedrock throttling (custom CloudWatch metric emitted by the backend)
- Nadlan collector failures (custom metric)
- RDS free storage < 2 GB
- ALB 5xx rate spikes

All of them just need `alarm_actions = [aws_sns_topic.alerts.arn]`.
