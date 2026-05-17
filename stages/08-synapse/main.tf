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

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_well_known_role" {
  name               = "${var.project_name}-matrix-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_well_known_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- 1b. Kod funkcji Lambda ---
resource "aws_lambda_function" "well_known" {
  filename      = "well_known.zip"
  function_name = "${var.project_name}-matrix-well-known"
  
  # ZMIANA: Używamy nowo stworzonej roli zamiast roli z ECS
  role          = aws_iam_role.lambda_well_known_role.arn
  
  handler       = "index.handler"
  runtime       = "python3.12"

  lifecycle {
    ignore_changes = [filename]
  }
  
  # Czekamy, aż rola zostanie w pełni przypisana, zanim stworzymy Lambdę
  depends_on = [aws_iam_role_policy_attachment.lambda_basic_execution]
}

# Tworzenie paczki zip z kodem w locie
resource "local_file" "lambda_code" {
  filename = "${path.module}/index.py"
  content  = <<EOT
import json

def handler(event, context):
    path = event.get('path', '')
    
    if 'server' in path:
        body = {"m.server": "matrix.${var.root_domain}:443"}
    else:
        body = {
            "m.homeserver": {"base_url": "https://matrix.${var.root_domain}"},
            "org.matrix.msc4143.rtc_foci": [{"type": "livekit", "livekit_service_url": "https://livekit-jwt.call.matrix.org"}],
            "im.vector.riot.jitsi": {"preferredDomain": "meet.jit.si"}
        }

    return {
        "statusCode": 200,
        "statusDescription": "200 OK",
        "isBase64Encoded": False,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type"
        },
        "body": json.dumps(body)
    }
EOT
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = local_file.lambda_code.filename
  output_path = "${path.module}/well_known.zip"
}

# Wymuszenie wgrania kodu przy tworzeniu
resource "null_resource" "lambda_trigger" {
  triggers = {
    code_hash = data.archive_file.lambda_zip.output_base64sha256
  }
  provisioner "local-exec" {
    command = "aws lambda update-function-code --function-name ${aws_lambda_function.well_known.function_name} --zip-file fileb://${data.archive_file.lambda_zip.output_path} --region ${var.aws_region}"
  }
  depends_on = [aws_lambda_function.well_known]
}

# 2. Target Group typu Lambda dla Load Balancera
resource "aws_lb_target_group" "matrix_well_known" {
  name        = "${var.project_name}-matrix-well-known"
  target_type = "lambda"
}

resource "aws_lambda_permission" "alb" {
  statement_id  = "AllowALBInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.well_known.function_name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.matrix_well_known.arn
}

resource "aws_lb_target_group_attachment" "matrix_well_known" {
  target_group_arn = aws_lb_target_group.matrix_well_known.arn
  target_id        = aws_lambda_function.well_known.arn
  depends_on       = [aws_lambda_permission.alb]
}

# 3. Nowa, pojedyncza reguła Load Balancera kierująca ruch /.well-known do Lambdy
resource "aws_lb_listener_rule" "matrix_well_known" {
  listener_arn = data.terraform_remote_state.platform.outputs.https_listener_arn
  priority     = 50

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.matrix_well_known.arn
  }

  condition {
    path_pattern {
      values = ["/.well-known/matrix/*"]
    }
  }
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
        "awslogs-region"        = var.aws_region 
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
