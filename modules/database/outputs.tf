output "endpoint" {
  value       = aws_db_instance.this.endpoint
  description = "Host:port of the RDS instance (for DATABASE_URL)."
}

output "address" {
  value       = aws_db_instance.this.address
  description = "Hostname only, without port."
}

output "port" {
  value       = aws_db_instance.this.port
  description = "DB port (5432)."
}

output "database_name" {
  value       = aws_db_instance.this.db_name
  description = "Initial database name (dara_v2)."
}

output "master_username" {
  value       = aws_db_instance.this.username
  description = "Master username (dara)."
}

output "identifier" {
  value       = aws_db_instance.this.identifier
  description = "DB instance identifier."
}

output "arn" {
  value       = aws_db_instance.this.arn
  description = "DB instance ARN."
}
