# CI/CD environment — GitHub Actions OIDC deploy roles, SSM hybrid
# activations, the shared artifact bucket, deploy document, log group, and
# failed-AssumeRole alarm for the dev/test/stg deploy ladder.
#
# Separate state key ("cicd/terraform.tfstate") so it never collides with
# dev/dev2/staging. Same S3 backend bucket + lock table as every other
# root. This root owns IAM + S3 + SSM + logging + alerting ONLY — it does
# not touch the dev/dev2/stg Lightsail boxes themselves (those stay in
# their own environments/* roots) and is not applied yet: apply is Ofek's
# activation step (see README.md).
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
    key            = "cicd/terraform.tfstate"
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
      Environment = "cicd"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# The GitHub Actions OIDC provider is a singleton per AWS account.
# modules/cicd already created it (applied against the staging stack's
# state) — a second `resource "aws_iam_openid_connect_provider"` here
# would fail at apply with "EntityAlreadyExists: Provider already exists
# for url". Look it up by URL instead of re-creating it.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ── One gha-deploy-env instance per ladder rung ────────────────────────

module "dev" {
  source = "../../modules/gha-deploy-env"

  project_name = var.project_name
  env_name     = "dev"
  branch       = "dev"
  github_repo  = var.github_repo

  oidc_provider_arn    = data.aws_iam_openid_connect_provider.github.arn
  artifact_bucket_arn  = aws_s3_bucket.artifacts.arn
  artifact_bucket_name = aws_s3_bucket.artifacts.id
  deploy_document_arn  = aws_ssm_document.gha_deploy.arn
  log_group_arn        = aws_cloudwatch_log_group.deploy.arn

  account_id = data.aws_caller_identity.current.account_id
  aws_region = var.aws_region

  managed_instance_id   = var.managed_instance_id_dev
  activation_expiration = var.ssm_activation_expiration
}

module "test" {
  source = "../../modules/gha-deploy-env"

  project_name = var.project_name
  env_name     = "test"
  branch       = "test"
  github_repo  = var.github_repo

  oidc_provider_arn    = data.aws_iam_openid_connect_provider.github.arn
  artifact_bucket_arn  = aws_s3_bucket.artifacts.arn
  artifact_bucket_name = aws_s3_bucket.artifacts.id
  deploy_document_arn  = aws_ssm_document.gha_deploy.arn
  log_group_arn        = aws_cloudwatch_log_group.deploy.arn

  account_id = data.aws_caller_identity.current.account_id
  aws_region = var.aws_region

  managed_instance_id   = var.managed_instance_id_test
  activation_expiration = var.ssm_activation_expiration
}

module "stg" {
  source = "../../modules/gha-deploy-env"

  project_name = var.project_name
  env_name     = "stg"
  branch       = "stg"
  github_repo  = var.github_repo

  oidc_provider_arn    = data.aws_iam_openid_connect_provider.github.arn
  artifact_bucket_arn  = aws_s3_bucket.artifacts.arn
  artifact_bucket_name = aws_s3_bucket.artifacts.id
  deploy_document_arn  = aws_ssm_document.gha_deploy.arn
  log_group_arn        = aws_cloudwatch_log_group.deploy.arn

  account_id = data.aws_caller_identity.current.account_id
  aws_region = var.aws_region

  managed_instance_id   = var.managed_instance_id_stg
  activation_expiration = var.ssm_activation_expiration
}
