output "static_ip" {
  description = "Public static IP of the dev box."
  value       = aws_lightsail_static_ip.dev.ip_address
}

output "instance_name" {
  value = aws_lightsail_instance.dev.name
}

output "private_key_pem" {
  description = "SSH private key for the dev box (write to a 600 file for ssh/rsync)."
  value       = aws_lightsail_key_pair.dev.private_key
  sensitive   = true
}

output "url" {
  description = "Dev app URL (HTTP; same-origin /api/ via Caddy)."
  value       = "http://${aws_lightsail_static_ip.dev.ip_address}"
}

output "ssh_command" {
  description = "Convenience SSH command (after the deploy script writes the key)."
  value       = "ssh -i dev_box_key.pem ubuntu@${aws_lightsail_static_ip.dev.ip_address}"
}
