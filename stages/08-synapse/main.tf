data "aws_region" "current" {}

# --- POBIERANIE ZMIENNYCH Z INNYCH WARSTW (REMOTE STATE) ---

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

# --- HASŁO DO BAZY SYNAPSE ORAZ UPRAWNIENIA ---

resource "random_password" "synapse_db" {
  length           = 64
  special          = true
  override_special = "!#$%&*()-_=+[]{}|;:,.<>?"
}

resource "aws_secretsmanager_secret" "synapse_db_password" {
  name                    = "${var.project_name}/synapse-db-password"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "synapse_db_password" {
  secret_id     = aws_secretsmanager_secret.synapse_db_password.id
  secret_string = random_password.synapse_db.result
}

# Ten blok automatycznie pozwala istniejącej roli z "02-infra" na odczyt naszego nowego hasła
resource "aws_iam_role_policy" "synapse_secret_access" {
  name   = "${var.project_name}-synapse-secret-access"
  # Wyciągamy nazwę roli z jej numeru ARN pobranego z remote_state
  role   = split("/", data.terraform_remote_state.infra.outputs.ecs_execution_role_arn)[1]
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.synapse_db_password.arn]
    }]
  })
}

# --- SECURITY GROUPS ---

resource "aws_security_group" "synapse_task" {
  name        = "${var.project_name}-synapse-task"
  description = "Security group for Synapse containers"
  vpc_id      = data.terraform_remote_state.infra.outputs.vpc_id

  ingress {
    from_port       = 8008
    to_port         = 8008
    protocol        = "tcp"
    security_groups = [data.terraform_remote_state.platform.outputs.alb_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "alb_egress_synapse" {
  type                     = "egress"
  from_port                = 8008
  to_port                  = 8008
  protocol                 = "tcp"
  security_group_id        = data.terraform_remote_state.platform.outputs.alb_sg_id
  source_security_group_id = aws_security_group.synapse_task.id
}

# --- DB SETUP (Inicjalizacja bazy w kontenerze) ---

resource "aws_cloudwatch_log_group" "db_setup" {
  name              = "/ecs/${var.project_name}/synapse-db-setup"
  retention_in_days = 7

  tags = { Name = "${var.project_name}-synapse-db-setup" }
}

resource "aws_ecs_task_definition" "db_setup" {
  family                   = "${var.project_name}-synapse-db-setup"
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
      "export PGPASSWORD=$DB_PASSWORD; psql -h $DB_HOST -U $DB_USER -d postgres -c \"CREATE ROLE synapse WITH LOGIN PASSWORD '$SYNAPSE_PASSWORD';\" -c \"CREATE DATABASE synapse OWNER synapse;\" || true"
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
        name      = "SYNAPSE_PASSWORD"
        valueFrom = aws_secretsmanager_secret.synapse_db_password.arn
      },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.db_setup.name
        "awslogs-region"        = data.aws_region.current.name
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

  depends_on = [aws_ecs_task_definition.db_setup, aws_iam_role_policy.synapse_secret_access]
}

# --- WYWOŁANIE MODUŁU SYNAPSE ---

module "synapse" {
  source                 = "../../modules/synapse"
  
  project_name           = var.project_name
  aws_region             = var.aws_region
  vpc_id                 = data.terraform_remote_state.infra.outputs.vpc_id
  subnets                = data.terraform_remote_state.infra.outputs.private_subnet_ids
  cluster_id             = data.terraform_remote_state.infra.outputs.ecs_cluster_id
  
  alb_listener_https_arn = data.terraform_remote_state.platform.outputs.https_listener_arn
  alb_dns_name           = data.terraform_remote_state.platform.outputs.alb_dns_name
  alb_zone_id            = data.terraform_remote_state.platform.outputs.alb_zone_id
  domain_name            = var.root_domain
  domain_zone_id         = data.terraform_remote_state.dns.outputs.zone_id

  db_host                = data.terraform_remote_state.infra.outputs.rds_address
  db_secret_arn          = aws_secretsmanager_secret.synapse_db_password.arn
  redis_endpoint         = data.terraform_remote_state.infra.outputs.redis_endpoint
  efs_id                 = data.terraform_remote_state.infra.outputs.efs_id

  execution_role_arn     = data.terraform_remote_state.infra.outputs.ecs_execution_role_arn
  task_role_arn          = data.terraform_remote_state.infra.outputs.ecs_execution_role_arn
  security_group_id      = aws_security_group.synapse_task.id

  # Czekamy na wykonanie zadania db_setup zanim uruchomimy sam serwer
  depends_on = [null_resource.run_db_setup] 
}