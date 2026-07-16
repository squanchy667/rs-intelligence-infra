# Feature environment — self-contained Terraform root.
#
# NAMING: this root (directory name "dev2", historical) manages the FEATURE
# box — new/experimental work deploys here first (`dev-deploy.sh feature`).
# The directory named "environments/dev" manages the shared dev box that QA
# tests on; that directory predates the split and must not be renamed (its
# state key and `environment` value are load-bearing — see DEV.md).
#
# Separate state key ("dev2/terraform.tfstate") so it never collides with the
# dev or staging roots (which hardcode "dev/terraform.tfstate" and
# "staging/terraform.tfstate" respectively). Same S3 backend bucket + lock
# table. This root wires ONLY the lean dev-box module — none of the
# ECS/ALB/NAT/RDS/CloudFront staging modules.
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  backend "s3" {
    bucket         = "rs-intelligence-terraform-state"
    key            = "dev2/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "rs-intelligence-terraform-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

module "dev_box" {
  source = "../../modules/dev-box"

  project_name      = var.project_name
  environment       = var.environment
  availability_zone = "${var.aws_region}a"
  bundle_id         = var.bundle_id
}
