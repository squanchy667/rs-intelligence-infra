# networking

VPC foundation for the RS Intelligence staging environment.

**Task:** T052

## What it creates

- **VPC** `10.0.0.0/16` (DNS hostnames + support enabled)
- **Subnets** in 2 AZs:
  - 2× public (`10.0.1.0/24`, `10.0.2.0/24`) — ALB, NAT
  - 2× private (`10.0.10.0/24`, `10.0.20.0/24`) — ECS tasks, RDS
- **Internet Gateway** attached to the VPC
- **Single NAT Gateway** in public subnet AZ 1 (staging cost optimisation — Multi-AZ NAT doubles the cost)
- **Route tables**: public → IGW, private → NAT
- **Security groups**:
  - `alb-sg`  — ingress 80/443 from `0.0.0.0/0` (CloudFront in practice)
  - `ecs-sg`  — ingress `container_port` (default 8000) from `alb-sg` only
  - `rds-sg`  — ingress 5432 from `ecs-sg` only
  - `vpce-sg` — ingress 443 from `ecs-sg` (for interface VPC endpoints)
- **VPC endpoints** (cut NAT data-transfer cost):
  - Gateway: S3
  - Interface: `ecr.api`, `ecr.dkr`, `secretsmanager`, `bedrock-runtime`, `logs`

## Outputs

`vpc_id`, `vpc_cidr`, `public_subnet_ids`, `private_subnet_ids`, `availability_zones`,
`alb_security_group_id`, `ecs_security_group_id`, `rds_security_group_id`,
`vpc_endpoints_security_group_id`.

## Variables

| Name | Default | Notes |
|------|---------|-------|
| `project_name` | — | resource prefix |
| `environment` | — | staging / production |
| `aws_region` | — | used for endpoint service names |
| `vpc_cidr` | `10.0.0.0/16` | |
| `public_subnet_cidrs` | `[10.0.1.0/24, 10.0.2.0/24]` | one per AZ |
| `private_subnet_cidrs` | `[10.0.10.0/24, 10.0.20.0/24]` | one per AZ |
| `container_port` | `8000` | FastAPI port, used on `ecs-sg` ingress rule |
