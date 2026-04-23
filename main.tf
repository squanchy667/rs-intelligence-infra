# RS Intelligence — root Terraform configuration.
#
# Backend bootstrap (run ONCE from an unconfigured repo — see README "First-time
# setup"):
#   1. Apply `bootstrap/` (not in this repo yet — see README) OR create manually:
#        aws s3 mb s3://rs-intelligence-terraform-state --region eu-west-1
#        aws s3api put-bucket-versioning \
#            --bucket rs-intelligence-terraform-state \
#            --versioning-configuration Status=Enabled
#        aws dynamodb create-table \
#            --table-name rs-intelligence-terraform-lock \
#            --attribute-definitions AttributeName=LockID,AttributeType=S \
#            --key-schema AttributeName=LockID,KeyType=HASH \
#            --billing-mode PAY_PER_REQUEST \
#            --region eu-west-1
#   2. Then `terraform init` will succeed against the remote backend.
terraform {
  backend "s3" {
    bucket         = "rs-intelligence-terraform-state"
    key            = "staging/terraform.tfstate"
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

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

############################################################################
# Module wiring
############################################################################

module "networking" {
  source = "./modules/networking"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
}

module "ecr" {
  source = "./modules/compute/ecr"

  project_name = var.project_name
  environment  = var.environment
}
