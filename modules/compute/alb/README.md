# compute/alb

Application Load Balancer in public subnets with an HTTP listener. No HTTPS
on the ALB — CloudFront (T058) terminates TLS and forwards plaintext HTTP
to this ALB.

**Task:** T057

## Resources

- `aws_lb.this` — internet-facing ALB on `alb-sg`, `drop_invalid_header_fields=true`
- `aws_lb_target_group.api` — IP target type (Fargate awsvpc), port 8000 HTTP,
  health check `GET /api/health` interval 30 s, healthy×2 / unhealthy×3,
  deregistration delay 30 s
- `aws_lb_listener.http` — :80 forwards to the target group

## Outputs

- `alb_dns_name` — used as the CloudFront `/api/*` origin host
- `target_group_arn` — ECS service in T060 attaches its tasks here
- `alb_arn`, `alb_zone_id`, `http_listener_arn`

## Why HTTP-only on the ALB

- CloudFront default certificate covers `*.cloudfront.net` for free
- ALB → ACM certificate would require DNS validation, which we don't have without a custom domain
- The ALB lives inside the VPC; the only external traffic reaching it is from CloudFront IPs. Staging-acceptable threat model.

Production-hardening (if we ever promote): add ACM cert + HTTPS listener,
restrict `alb-sg` to CloudFront-managed prefix list
(`com.amazonaws.global.cloudfront.origin-facing`).
