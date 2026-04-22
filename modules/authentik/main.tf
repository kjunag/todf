data "aws_region" "current" {}

# --- Security Groups ---

resource "aws_security_group" "app" {
  name        = "${var.project_name}-authentik-app"
  description = "Authentik server and worker containers"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-authentik-app" }
}

resource "aws_security_group_rule" "app_ingress_from_alb" {
  type                     = "ingress"
  from_port                = 9000
  to_port                  = 9000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = var.alb_sg_id
  description              = "Traffic from ALB"
}

resource "aws_security_group_rule" "alb_egress_to_app" {
  type                     = "egress"
  from_port                = 9000
  to_port                  = 9000
  protocol                 = "tcp"
  security_group_id        = var.alb_sg_id
  source_security_group_id = aws_security_group.app.id
  description              = "Traffic to Authentik containers"
}

# --- IAM Task Role ---

resource "aws_iam_role" "task" {
  name = "${var.project_name}-authentik-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "task_exec_command" {
  name = "${var.project_name}-authentik-exec-command"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

# --- EFS Access Point ---

resource "aws_efs_access_point" "media" {
  file_system_id = var.efs_id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/authentik/media"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "755"
    }
  }

  tags = { Name = "${var.project_name}-authentik-media" }
}

# --- CloudWatch Logs ---

resource "aws_cloudwatch_log_group" "authentik" {
  name              = "/ecs/${var.project_name}/authentik"
  retention_in_days = 30

  tags = { Name = "${var.project_name}-authentik" }
}

# --- ECS Task Definitions ---

locals {
  redis_host = var.redis_endpoint

  common_env = [
    { name = "AUTHENTIK_REDIS__HOST", value = local.redis_host },
    { name = "AUTHENTIK_POSTGRESQL__HOST", value = var.db_endpoint },
    { name = "AUTHENTIK_POSTGRESQL__NAME", value = "authentik" },
    { name = "AUTHENTIK_POSTGRESQL__USER", value = "authentik" },
    { name = "AUTHENTIK_ERROR_REPORTING__ENABLED", value = "false" },
    { name = "AUTHENTIK_LOG_LEVEL", value = "info" },
  ]

  common_secrets = [
    {
      name      = "AUTHENTIK_POSTGRESQL__PASSWORD"
      valueFrom = "${var.db_secret_arn}:password::"
    },
    {
      name      = "AUTHENTIK_SECRET_KEY"
      valueFrom = var.secret_key_arn
    },
    {
      name      = "AUTHENTIK_BOOTSTRAP_PASSWORD"
      valueFrom = var.authentik_bootstrap_password_arn
    },
  ]

  media_mount = [{
    containerPath = "/media"
    sourceVolume  = "authentik-media"
    readOnly      = false
  }]
}

resource "aws_ecs_task_definition" "server" {
  family                   = "${var.project_name}-authentik-server"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "authentik-server"
    image     = "ghcr.io/goauthentik/server:${var.authentik_version}"
    command   = ["server"]
    essential = true

    portMappings = [{
      containerPort = 9000
      hostPort      = 9000
      protocol      = "tcp"
    }]

    environment  = local.common_env
    secrets      = local.common_secrets
    mountPoints  = local.media_mount

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.authentik.name
        "awslogs-region"        = data.aws_region.current.id
        "awslogs-stream-prefix" = "server"
      }
    }
  }])

  volume {
    name = "authentik-media"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.media.id
        iam             = "DISABLED"
      }
    }
  }

  tags = { Name = "${var.project_name}-authentik-server" }
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.project_name}-authentik-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "authentik-worker"
    image     = "ghcr.io/goauthentik/server:${var.authentik_version}"
    command   = ["worker"]
    essential = true

    environment = local.common_env
    secrets     = local.common_secrets
    mountPoints = local.media_mount

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.authentik.name
        "awslogs-region"        = data.aws_region.current.id
        "awslogs-stream-prefix" = "worker"
      }
    }
  }])

  volume {
    name = "authentik-media"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.media.id
        iam             = "DISABLED"
      }
    }
  }

  tags = { Name = "${var.project_name}-authentik-worker" }
}

# --- ALB Target Group & Listener Rule ---

resource "aws_lb_target_group" "authentik" {
  name        = "${var.project_name}-authentik"
  port        = 9000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/-/health/live/"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "${var.project_name}-authentik" }
}

resource "aws_lb_listener_rule" "authentik" {
  listener_arn = var.https_listener_arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.authentik.arn
  }

  condition {
    host_header {
      values = ["auth.${var.root_domain}"]
    }
  }
}

# --- ECS Services ---

resource "aws_ecs_service" "server" {
  name                   = "${var.project_name}-authentik-server"
  cluster                = var.ecs_cluster_id
  task_definition        = aws_ecs_task_definition.server.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = var.private_subnets
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.authentik.arn
    container_name   = "authentik-server"
    container_port   = 9000
  }

  depends_on = [aws_lb_listener_rule.authentik]

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = { Name = "${var.project_name}-authentik-server" }
}

resource "aws_ecs_service" "worker" {
  name                   = "${var.project_name}-authentik-worker"
  cluster                = var.ecs_cluster_id
  task_definition        = aws_ecs_task_definition.worker.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = var.private_subnets
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = { Name = "${var.project_name}-authentik-worker" }
}
