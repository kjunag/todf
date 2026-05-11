# --- DNS ---
resource "aws_route53_record" "synapse" {
  zone_id = var.domain_zone_id
  name    = "matrix.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# --- ALB TARGET GROUP & RULE ---
resource "aws_lb_target_group" "synapse" {
  name        = "${var.project_name}-synapse-tg"
  port        = 8008
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/_matrix/client/versions"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }
}

resource "aws_lb_listener_rule" "synapse" {
  listener_arn = var.alb_listener_https_arn
  priority     = 120 # Upewnij się, że nie koliduje z Nextcloud/Authentik

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.synapse.arn
  }

  condition {
    host_header {
      values = ["matrix.${var.domain_name}"]
    }
  }
}

# --- EFS ACCESS POINT ---
resource "aws_efs_access_point" "synapse" {
  file_system_id = var.efs_id
  posix_user {
    gid = 991 # Domyślny GID dla kontenera matrixdotorg/synapse
    uid = 991 # Domyślny UID dla kontenera matrixdotorg/synapse
  }
  root_directory {
    path = "/synapse"
    creation_info {
      owner_gid   = 991
      owner_uid   = 991
      permissions = "0755"
    }
  }
}

# --- ECS TASK & SERVICE ---
resource "aws_ecs_task_definition" "synapse" {
  family                   = "${var.project_name}-synapse"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  volume {
    name = "synapse-data"
    efs_volume_configuration {
      file_system_id          = var.efs_id
      transit_encryption      = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.synapse.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name  = "synapse"
      image = "matrixdotorg/synapse:latest"
      portMappings = [
        {
          containerPort = 8008
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "SYNAPSE_SERVER_NAME", value = "matrix.${var.domain_name}" },
        { name = "SYNAPSE_REPORT_STATS", value = "no" },
        { name = "SYNAPSE_CONFIG_DIR", value = "/data" },
        { name = "SYNAPSE_CONFIG_PATH", value = "/data/homeserver.yaml" },
        { name = "POSTGRES_USER", value = "synapse" },
        { name = "POSTGRES_HOST", value = var.db_host },
        { name = "REDIS_HOST", value = var.redis_endpoint },
      ]
      secrets = [
        {
          name      = "POSTGRES_PASSWORD"
          valueFrom = var.db_secret_arn
        }
      ]
      mountPoints = [
        {
          sourceVolume  = "synapse-data"
          containerPath = "/data"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${var.project_name}-synapse"
          "awslogs-region"        = var.aws_region # Zmień na właściwy jeśli używasz innego regionu
          "awslogs-stream-prefix" = "synapse"
        }
      }
    }
  ])
}

resource "aws_cloudwatch_log_group" "synapse" {
  name              = "/ecs/${var.project_name}-synapse"
  retention_in_days = 7
}

resource "aws_ecs_service" "synapse" {
  name            = "${var.project_name}-synapse"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.synapse.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnets
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.synapse.arn
    container_name   = "synapse"
    container_port   = 8008
  }

  enable_execute_command = true 

  depends_on = [aws_lb_listener_rule.synapse, null_resource.generate_synapse_config]
}


resource "null_resource" "generate_synapse_config" {
  triggers = {
    # Odpal ponownie tylko jeśli zmieni się definicja taska
    task_arn = aws_ecs_task_definition.synapse.arn
  }

  provisioner "local-exec" {
    command = <<EOT
      aws ecs run-task \
        --cluster ${var.cluster_id} \
        --task-definition ${aws_ecs_task_definition.synapse.arn} \
        --launch-type FARGATE \
        --network-configuration 'awsvpcConfiguration={subnets=["${var.subnets[0]}"],securityGroups=["${var.security_group_id}"]}' \
        --overrides '{"containerOverrides": [{"name": "synapse", "command": ["generate"]}]}' \
        --region ${var.aws_region}
    EOT
  }

  # Musi poczekać aż powstanie Task Definition i Access Point EFS
  depends_on = [
    aws_ecs_task_definition.synapse,
    aws_efs_access_point.synapse
  ]
}