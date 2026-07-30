output "static_ip" {
  value = module.dev_box.static_ip
}

output "url" {
  value = module.dev_box.url
}

output "ssh_command" {
  value = module.dev_box.ssh_command
}

output "private_key_pem" {
  value     = module.dev_box.private_key_pem
  sensitive = true
}
