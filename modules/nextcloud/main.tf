# --- 1. CLOUDWATCH LOGS ---
resource "aws_cloudwatch_log_group" "nextcloud" {
  name              = "/ecs/${var.project_name}/nextcloud"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "collabora" {
  name              = "/ecs/${var.project_name}/collabora"
  retention_in_days = 7
}

# --- 2. EFS ACCESS POINT  ---
resource "aws_efs_access_point" "nextcloud_data" {
  file_system_id = var.efs_id

  posix_user {
    gid = 33 
    uid = 33
  }

  root_directory {
    path = "/nextcloud-data-v2"
    creation_info {
      owner_gid   = 33
      owner_uid   = 33
      permissions = "0755"
    }
  }
}

# --- 3. TARGET GROUPY  ---
resource "aws_lb_target_group" "nextcloud" {
  name        = "${var.project_name}-nc-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/status.php" 
    healthy_threshold   = 3
    unhealthy_threshold = 10
    timeout             = 25
    interval            = 30
    matcher             = "200-499"
  }
}

resource "aws_lb_target_group" "collabora" {
  name        = "${var.project_name}-collab-tg"
  port        = 9980
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/hosting/discovery" 
    healthy_threshold   = 3
    unhealthy_threshold = 10
    timeout             = 25
    interval            = 30
    matcher             = "200-499"
  }
}

# --- 4. ALB LISTENER RULES ---
resource "aws_lb_listener_rule" "nextcloud" {
  listener_arn = var.alb_listener_https_arn
  priority     = 20 

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nextcloud.arn
  }

  condition {
    host_header {
      values = ["cloud.${var.domain_name}"]
    }
  }
}

resource "aws_lb_listener_rule" "collabora" {
  listener_arn = var.alb_listener_https_arn
  priority     = 25

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.collabora.arn
  }

  condition {
    host_header {
      values = ["office.${var.domain_name}"]
    }
  }
}

# --- 5. ROUTE 53 ---
resource "aws_route53_record" "nextcloud" {
  zone_id = var.domain_zone_id
  name    = "cloud.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "collabora" {
  zone_id = var.domain_zone_id
  name    = "office.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

data "aws_region" "current" {}

# --- 6. TASK DEFINITION  ---
resource "aws_ecs_task_definition" "nextcloud" {
  family                   = "${var.project_name}-nextcloud"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "2048" # 2 vCPU
  memory                   = "4096" # 4 GB RAM (Nextcloud i Collabora potrzebują trochę zasobów)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  volume {
    name = "nextcloud-data"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.nextcloud_data.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "nextcloud"
      image     = "nextcloud:apache"
      essential = true
      
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "POSTGRES_DB", value = "nextcloud" },
        { name = "POSTGRES_USER", value = "nextcloud" },
        { name = "POSTGRES_HOST", value = var.db_host },
        { name = "REDIS_HOST", value = var.redis_endpoint },
        { name = "NEXTCLOUD_TRUSTED_DOMAINS", value = "cloud.${var.domain_name}" },
        { name = "OVERWRITEPROTOCOL", value = "https" },
        { name = "OVERWRITECLIURL", value = "https://cloud.${var.domain_name}" }
      ]

      secrets = [
        {
          name      = "POSTGRES_PASSWORD"
          valueFrom = var.db_secret_arn
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "nextcloud-data"
          containerPath = "/var/www/html"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.nextcloud.name
          "awslogs-region"        = data.aws_region.current.id
          "awslogs-stream-prefix" = "app"
        }
      }
    },
    {
      name      = "collabora"
      image     = "collabora/code:latest"
      essential = true

      portMappings = [
        {
          containerPort = 9980
          hostPort      = 9980
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "aliasgroup1", value = "https://cloud.${var.domain_name}:443" },
        { name = "extra_params", value = "--o:ssl.enable=false --o:ssl.termination=true --o:security.capabilities=false --o:security.seccomp=false --o:security.namespaces=false" },
        { name = "dictionaries", value = "pl_PL,en_US" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.collabora.name
          "awslogs-region"        = data.aws_region.current.id
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])
}

# --- 7. ECS SERVICE ---
resource "aws_ecs_service" "nextcloud" {
  name                   = "${var.project_name}-nextcloud"
  cluster                = var.cluster_id
  task_definition        = aws_ecs_task_definition.nextcloud.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true # Zostawiamy tunel do debugowania!
  
  health_check_grace_period_seconds = 1200

  depends_on = [
    aws_lb_listener_rule.nextcloud,
    aws_lb_listener_rule.collabora
  ]

  network_configuration {
    subnets          = var.subnets
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.nextcloud.arn
    container_name   = "nextcloud"
    container_port   = 80
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.collabora.arn
    container_name   = "collabora"
    container_port   = 9980
  }
}
