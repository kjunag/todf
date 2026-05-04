data "terraform_remote_state" "dns" {
  backend = "s3"
  config = {
    bucket         = var.tf_state_bucket
    key            = "stages/01-dns/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = var.tf_state_lock_table
    encrypt        = true
  }
}

data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket         = var.tf_state_bucket
    key            = "stages/02-infra/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = var.tf_state_lock_table
    encrypt        = true
  }
}

data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket         = var.tf_state_bucket
    key            = "stages/03-platform/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = var.tf_state_lock_table
    encrypt        = true
  }
}

module "authentik" {
  source                           = "../../modules/authentik"
  project_name                     = var.project_name
  vpc_id                           = data.terraform_remote_state.infra.outputs.vpc_id
  private_subnets                  = data.terraform_remote_state.infra.outputs.private_subnet_ids
  efs_id                           = data.terraform_remote_state.infra.outputs.efs_id
  ecs_cluster_id                   = data.terraform_remote_state.infra.outputs.ecs_cluster_id
  ecs_execution_role_arn           = data.terraform_remote_state.infra.outputs.ecs_execution_role_arn
  db_endpoint                      = data.terraform_remote_state.infra.outputs.rds_address
  db_secret_arn                    = data.terraform_remote_state.infra.outputs.db_secret_arn
  secret_key_arn                   = data.terraform_remote_state.infra.outputs.secret_key_arn
  authentik_bootstrap_password_arn = data.terraform_remote_state.infra.outputs.authentik_bootstrap_password_arn
  alb_sg_id                        = data.terraform_remote_state.platform.outputs.alb_sg_id
  https_listener_arn               = data.terraform_remote_state.platform.outputs.https_listener_arn
  root_domain                      = var.root_domain
  redis_endpoint                   = data.terraform_remote_state.infra.outputs.redis_endpoint
  authentik_version                = var.authentik_version
  email_host                       = var.email_host
  email_port                       = var.email_port
  email_username                   = var.email_username
  email_from                       = var.email_from
  email_password_arn               = data.terraform_remote_state.infra.outputs.resend_smtp_secret_arn
}

resource "aws_route53_record" "authentik" {
  zone_id = data.terraform_remote_state.dns.outputs.zone_id
  name    = "auth.${var.root_domain}"
  type    = "A"

  alias {
    name                   = data.terraform_remote_state.platform.outputs.alb_dns_name
    zone_id                = data.terraform_remote_state.platform.outputs.alb_zone_id
    evaluate_target_health = true
  }
}
