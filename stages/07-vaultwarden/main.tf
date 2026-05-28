data "terraform_remote_state" "authentik" {
  backend = "s3"
  config = {
    bucket         = var.tf_state_bucket
    key            = "stages/04-authentik/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = var.tf_state_lock_table
    encrypt        = true
  }
}

data "aws_secretsmanager_secret_version" "authentik_token" {
  secret_id = data.terraform_remote_state.authentik.outputs.authentik_api_token_secret_arn
}

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

data "aws_region" "current" {}

# --- DB setup (one-time ECS task to create vaultwarden database in shared RDS) ---

resource "aws_cloudwatch_log_group" "db_setup" {
  name              = "/ecs/${var.project_name}/vaultwarden-db-setup"
  retention_in_days = 7

  tags = { Name = "${var.project_name}-vaultwarden-db-setup" }
}

resource "aws_ecs_task_definition" "db_setup" {
  family                   = "${var.project_name}-vaultwarden-db-setup"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = data.terraform_remote_state.infra.outputs.ecs_execution_role_arn
  task_role_arn            = data.terraform_remote_state.infra.outputs.ecs_execution_role_arn

  container_definitions = jsonencode([{
    name      = "db-setup"
    image     = "postgres:alpine"
    essential = true

    command = [
      "sh", "-c",
      "export PGPASSWORD=$DB_PASSWORD; psql -h $DB_HOST -U $DB_USER -d postgres -c \"CREATE ROLE vaultwarden WITH LOGIN PASSWORD '$VAULTWARDEN_PASSWORD';\" -c \"CREATE DATABASE vaultwarden OWNER vaultwarden;\" || true"
    ]

    environment = [
      { name = "DB_HOST", value = data.terraform_remote_state.infra.outputs.rds_address },
      { name = "DB_USER", value = "authentik" },
    ]

    secrets = [
      {
        name      = "DB_PASSWORD"
        valueFrom = "${data.terraform_remote_state.infra.outputs.db_secret_arn}:password::"
      },
      {
        name      = "VAULTWARDEN_PASSWORD"
        valueFrom = data.terraform_remote_state.infra.outputs.vaultwarden_db_password_arn
      },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.db_setup.name
        "awslogs-region"        = data.aws_region.current.id
        "awslogs-stream-prefix" = "db-setup"
      }
    }
  }])
}

resource "null_resource" "run_db_setup" {
  triggers = {
    task_arn = aws_ecs_task_definition.db_setup.arn
  }

  provisioner "local-exec" {
    command = <<EOT
      aws ecs run-task \
        --cluster ${data.terraform_remote_state.infra.outputs.ecs_cluster_id} \
        --task-definition ${aws_ecs_task_definition.db_setup.arn} \
        --launch-type FARGATE \
        --network-configuration 'awsvpcConfiguration={subnets=["${data.terraform_remote_state.infra.outputs.private_subnet_ids[0]}"],securityGroups=["${data.terraform_remote_state.infra.outputs.rds_sg_id}"]}' \
        --region ${var.aws_region}
    EOT
  }

  depends_on = [aws_ecs_task_definition.db_setup]
}

# --- Vaultwarden ---

module "vaultwarden" {
  source                      = "../../modules/vaultwarden"
  project_name                = var.project_name
  vpc_id                      = data.terraform_remote_state.infra.outputs.vpc_id
  private_subnets             = data.terraform_remote_state.infra.outputs.private_subnet_ids
  ecs_cluster_id              = data.terraform_remote_state.infra.outputs.ecs_cluster_id
  ecs_execution_role_arn      = data.terraform_remote_state.infra.outputs.ecs_execution_role_arn
  efs_id                      = data.terraform_remote_state.infra.outputs.efs_id
  db_host                     = data.terraform_remote_state.infra.outputs.rds_address
  vaultwarden_db_password_arn = data.terraform_remote_state.infra.outputs.vaultwarden_db_password_arn
  admin_token_arn             = data.terraform_remote_state.infra.outputs.vaultwarden_admin_token_arn
  alb_sg_id                   = data.terraform_remote_state.platform.outputs.alb_sg_id
  https_listener_arn          = data.terraform_remote_state.platform.outputs.https_listener_arn
  alb_dns_name                = data.terraform_remote_state.platform.outputs.alb_dns_name
  alb_zone_id                 = data.terraform_remote_state.platform.outputs.alb_zone_id
  domain_name                 = var.root_domain
  domain_zone_id              = data.terraform_remote_state.dns.outputs.zone_id
  vaultwarden_image           = var.vaultwarden_image
  authentik_url               = data.terraform_remote_state.authentik.outputs.authentik_url

  depends_on = [null_resource.run_db_setup]
}
