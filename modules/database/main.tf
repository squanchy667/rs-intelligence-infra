locals {
  name = "${var.project_name}-${var.environment}"
}

resource "aws_db_subnet_group" "this" {
  name        = "${local.name}-db-subnets"
  description = "Private subnets for ${local.name} RDS"
  subnet_ids  = var.private_subnet_ids

  tags = { Name = "${local.name}-db-subnets" }
}

# Enable pg_stat_statements so we can inspect slow queries in CloudWatch.
resource "aws_db_parameter_group" "this" {
  name        = "${local.name}-pg16"
  family      = "postgres16"
  description = "PostgreSQL 16 parameter group for ${local.name}"

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
    # shared_preload_libraries is a static GUC → requires DB reboot
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # log any query > 1 s
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${local.name}-postgres"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  # Storage — gp3 with autoscaling headroom
  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true

  # Network — private only, no public endpoint
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = false # staging cost optimisation

  # Credentials + initial DB
  db_name  = var.database_name
  username = var.master_username
  password = var.master_password
  port     = 5432

  # Parameter group
  parameter_group_name = aws_db_parameter_group.this.name

  # Backups
  backup_retention_period = var.backup_retention_days
  backup_window           = var.backup_window
  maintenance_window      = var.maintenance_window
  copy_tags_to_snapshot   = true
  deletion_protection     = false # staging — easy teardown
  skip_final_snapshot     = true  # staging — no final snapshot on destroy

  # Observability
  performance_insights_enabled          = false # not free on t4g.micro in all regions
  enabled_cloudwatch_logs_exports       = ["postgresql"]
  auto_minor_version_upgrade            = true

  # Apply parameter-group changes on next window so a `terraform apply` won't
  # force an immediate restart during the day.
  apply_immediately = false

  tags = {
    Name = "${local.name}-postgres"
  }
}
