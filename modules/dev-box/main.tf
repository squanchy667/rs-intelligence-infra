# Dev box — a single Lightsail instance running the whole app via docker-compose
# (postgres + api + caddy, NO Ollama). Deliberately NOT the ECS/ALB/NAT/RDS
# staging architecture: this tier exists to be cheap (~$5/mo) and always-on for
# day-to-day testing. Staging stays the real integration gate.

locals {
  name = "${var.project_name}-${var.environment}"
}

# A Lightsail-managed SSH key pair so the deploy scripts can reach the box
# without a pre-existing key. The private key is a sensitive output; the deploy
# script writes it to a local file (chmod 600) for ssh/rsync.
resource "aws_lightsail_key_pair" "dev" {
  name = "${local.name}-key"
}

# user_data installs Docker Engine + the compose plugin so the box is ready for
# the artifact-push deploy (scripts/dev-deploy.sh). No app build happens here.
resource "aws_lightsail_instance" "dev" {
  name              = "${local.name}-box"
  availability_zone = var.availability_zone
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  key_pair_name     = aws_lightsail_key_pair.dev.name

  # NB: Lightsail/cloud-init runs user_data under /bin/sh (dash), and the heredoc
  # indentation strips the shebang anyway — so this MUST be POSIX-sh compatible
  # (no `set -o pipefail`, no bashisms).
  user_data = <<-EOF
    #!/bin/sh
    set -eu
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    usermod -aG docker ubuntu
    install -d -o ubuntu -g ubuntu /opt/dara
    touch /opt/dara/.cloud-init-done
  EOF

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Stable public IP so the URL / UI api-origin doesn't change across reboots.
resource "aws_lightsail_static_ip" "dev" {
  name = "${local.name}-ip"
}

resource "aws_lightsail_static_ip_attachment" "dev" {
  static_ip_name = aws_lightsail_static_ip.dev.name
  instance_name  = aws_lightsail_instance.dev.name
}

# Firewall: SSH + HTTP (+ HTTPS reserved for a future domain/Caddy-TLS).
resource "aws_lightsail_instance_public_ports" "dev" {
  instance_name = aws_lightsail_instance.dev.name

  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
  }
  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
  }
  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
  }
}
