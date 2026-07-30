# Stg environment — self-contained Terraform root. SCAFFOLD ONLY, see
# README.md — do not apply until the stg box is green-lit.
#
# Separate state key ("stg/terraform.tfstate") so it never collides with
# dev/dev2/staging/cicd. Same S3 backend bucket + lock table. This root
# wires ONLY the lean dev-box module — none of the ECS/ALB/NAT/RDS/
# CloudFront staging modules — mirroring environments/dev's shape exactly.
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
    key            = "stg/terraform.tfstate"
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
