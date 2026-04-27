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

module "secrets" {
  source = "./modules/secrets"

  project_name = var.project_name
  environment  = var.environment
}

module "database" {
  source = "./modules/database"

  project_name       = var.project_name
  environment        = var.environment
  private_subnet_ids = module.networking.private_subnet_ids
  security_group_id  = module.networking.rds_security_group_id
  master_password    = module.secrets.rds_password
}

module "alb" {
  source = "./modules/compute/alb"

  project_name      = var.project_name
  environment       = var.environment
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
  security_group_id = module.networking.alb_security_group_id
}

module "storage" {
  source = "./modules/storage"

  project_name = var.project_name
  environment  = var.environment
  alb_dns_name = module.alb.alb_dns_name
}

module "ecs" {
  source = "./modules/compute/ecs"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region

  private_subnet_ids    = module.networking.private_subnet_ids
  ecs_security_group_id = module.networking.ecs_security_group_id

  ecr_repository_url = module.ecr.repository_url
  ecr_repository_arn = module.ecr.repository_arn

  alb_target_group_arn = module.alb.target_group_arn

  rds_endpoint        = module.database.endpoint
  rds_database_name   = module.database.database_name
  rds_master_username = module.database.master_username
  rds_master_password = module.secrets.rds_password

  jwt_secret_arn                  = module.secrets.jwt_secret_arn
  nadlan_recaptcha_key_secret_arn = module.secrets.nadlan_recaptcha_key_secret_arn
  rds_password_secret_arn         = module.secrets.rds_password_secret_arn
  ecs_read_policy_json            = module.secrets.ecs_read_policy_json

  seed_bucket_arn = var.seed_bucket_arn
}

module "scheduling" {
  source = "./modules/scheduling"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region

  ecs_cluster_arn             = module.ecs.cluster_arn
  ecs_task_definition_arn     = module.ecs.task_definition_arn
  ecs_task_execution_role_arn = module.ecs.task_execution_role_arn
  ecs_task_role_arn           = module.ecs.task_role_arn

  private_subnet_ids     = module.networking.private_subnet_ids
  ecs_security_group_id  = module.networking.ecs_security_group_id

  enable_daily_sync    = var.scheduling_enable_daily_sync
  enable_weekly_report = var.scheduling_enable_weekly_report
}

module "monitoring" {
  source = "./modules/monitoring"

  project_name = var.project_name
  environment  = var.environment
  alert_email  = var.alert_email

  alb_arn_suffix              = module.alb.alb_arn_suffix
  alb_target_group_arn_suffix = module.alb.target_group_arn_suffix

  ecs_cluster_name = module.ecs.cluster_name
  ecs_service_name = module.ecs.service_name
}

module "cicd" {
  source = "./modules/cicd"

  project_name = var.project_name
  environment  = var.environment

  ecr_repository_arn          = module.ecr.repository_arn
  ecs_cluster_arn             = module.ecs.cluster_arn
  ecs_service_arn_pattern     = "arn:aws:ecs:${var.aws_region}:*:service/${module.ecs.cluster_name}/*"
  ecs_task_execution_role_arn = module.ecs.task_execution_role_arn
  ecs_task_role_arn           = module.ecs.task_role_arn

  frontend_bucket_arn         = "arn:aws:s3:::${module.storage.bucket_name}"
  cloudfront_distribution_arn = module.storage.cloudfront_distribution_arn
}
