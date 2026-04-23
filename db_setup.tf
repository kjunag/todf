resource "random_password" "nextcloud_db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "nextcloud_db_password" {
  name                    = "${var.project_name}/nextcloud-db-password"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "nextcloud_db_password" {
  secret_id     = aws_secretsmanager_secret.nextcloud_db_password.id
  secret_string = random_password.nextcloud_db.result
}

resource "aws_cloudwatch_log_group" "db_setup" {
  name              = "/ecs/${var.project_name}/db-setup"
  retention_in_days = 7

  tags = { Name = "${var.project_name}-db-setup" }
}

resource "aws_ecs_task_definition" "db_setup" {
  family                   = "${var.project_name}-db-setup"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_execution_role.arn # Używamy roli egzekucyjnej do połączenia

  container_definitions = jsonencode([{
    name  = "db-setup"
    image = "postgres:alpine"
    essential = true
    
    command = [
      "sh", "-c",
      "export PGPASSWORD=$DB_PASSWORD; psql -h $DB_HOST -U $DB_USER -d postgres -c \"CREATE ROLE nextcloud WITH LOGIN PASSWORD '$NEXTCLOUD_PASSWORD';\" -c \"CREATE DATABASE nextcloud OWNER nextcloud;\""
    ]

    environment = [
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "DB_USER", value = aws_db_instance.main.username },
      { name = "NEXTCLOUD_PASSWORD", value = random_password.nextcloud_db.result }
    ]

    secrets = [
      {
        name      = "DB_PASSWORD"
        valueFrom = "${aws_secretsmanager_secret.db_password.arn}:password::"
      }
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
        --cluster ${aws_ecs_cluster.main.id} \
        --task-definition ${aws_ecs_task_definition.db_setup.arn} \
        --launch-type FARGATE \
        --network-configuration 'awsvpcConfiguration={subnets=["${aws_subnet.private[0].id}"],securityGroups=["${aws_security_group.rds.id}"]}' \
        --region ${var.aws_region}
    EOT
  }

  depends_on = [aws_db_instance.main, aws_ecs_task_definition.db_setup]
}
