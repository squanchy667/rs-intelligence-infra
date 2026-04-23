locals {
  name = "${var.project_name}-${var.environment}"
  # ALB name max 32 chars, alphanumeric + hyphen
  alb_name    = substr("${local.name}-alb", 0, 32)
  target_name = substr("${local.name}-tg", 0, 32)
}

resource "aws_lb" "this" {
  name               = local.alb_name
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [var.security_group_id]

  # Drop invalid-header requests (CloudFront is well-behaved; we don't need
  # to preserve malformed traffic).
  drop_invalid_header_fields = true
  idle_timeout               = 60

  tags = { Name = local.alb_name }
}

# IP-type target group for Fargate awsvpc mode.
resource "aws_lb_target_group" "api" {
  name        = local.target_name
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  deregistration_delay = var.deregistration_delay_seconds

  health_check {
    enabled             = true
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = local.target_name }
}

# HTTP listener — CloudFront handles SSL, so no 443 listener on the ALB itself.
# 80 forwards to the target group. The ALB security group only accepts 80/443
# from the internet (CloudFront in practice), but since CF is the only
# reachable frontend we don't need 443 on the ALB.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
