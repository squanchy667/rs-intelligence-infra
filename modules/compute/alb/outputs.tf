output "alb_arn" {
  value       = aws_lb.this.arn
  description = "ALB ARN (for CloudFront origin + listener ACLs)."
}

output "alb_dns_name" {
  value       = aws_lb.this.dns_name
  description = "ALB public DNS — consumed as CloudFront custom origin in T058."
}

output "alb_zone_id" {
  value       = aws_lb.this.zone_id
  description = "Route53 alias zone ID if we ever add a custom domain."
}

output "target_group_arn" {
  value       = aws_lb_target_group.api.arn
  description = "Target group ARN — ECS service (T060) attaches here."
}

output "target_group_name" {
  value       = aws_lb_target_group.api.name
  description = "Target group name."
}

output "http_listener_arn" {
  value       = aws_lb_listener.http.arn
  description = "HTTP listener ARN."
}
