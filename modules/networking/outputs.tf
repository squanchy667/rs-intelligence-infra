output "vpc_id" {
  value       = aws_vpc.this.id
  description = "VPC ID."
}

output "vpc_cidr" {
  value       = aws_vpc.this.cidr_block
  description = "VPC CIDR block."
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "Public subnets (ALB, NAT)."
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "Private subnets (ECS, RDS)."
}

output "availability_zones" {
  value       = local.az_list
  description = "The 2 AZs used for subnets."
}

output "alb_security_group_id" {
  value       = aws_security_group.alb.id
  description = "Security group for the Application Load Balancer."
}

output "ecs_security_group_id" {
  value       = aws_security_group.ecs.id
  description = "Security group for ECS Fargate tasks."
}

output "rds_security_group_id" {
  value       = aws_security_group.rds.id
  description = "Security group for the RDS PostgreSQL instance."
}

output "vpc_endpoints_security_group_id" {
  value       = aws_security_group.vpc_endpoints.id
  description = "Security group attached to interface VPC endpoints."
}
