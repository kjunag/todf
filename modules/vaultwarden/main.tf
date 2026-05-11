terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    authentik = {
      source = "goauthentik/authentik"
    }
  }
}

data "aws_region" "current" {}

# --- Security Groups ---

resource "aws_security_group" "app" {
  name        = "${var.project_name}-vaultwarden-app"
  description = "Vaultwarden containers"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-vaultwarden-app" }
}

resource "aws_security_group_rule" "app_ingress_from_alb" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = var.alb_sg_id
  description              = "Traffic from ALB"
}

resource "aws_security_group_rule" "alb_egress_to_app" {
  type                     = "egress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = var.alb_sg_id
  source_security_group_id = aws_security_group.app.id
  description              = "Traffic to Vaultwarden containers"
}

# --- IAM Task Role ---

resource "aws_iam_role" "task" {
  name = "${var.project_name}-vaultwarden-task-role"

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
  name = "${var.project_name}-vaultwarden-exec-command"
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

resource "aws_efs_access_point" "data" {
  file_system_id = var.efs_id

  posix_user {
    uid = 3000
    gid = 3000
  }

  root_directory {
    path = "/vaultwarden"
    creation_info {
      owner_uid   = 3000
      owner_gid   = 3000
      permissions = "755"
    }
  }

  tags = { Name = "${var.project_name}-vaultwarden-data" }
}

# --- CloudWatch Logs ---

resource "aws_cloudwatch_log_group" "vaultwarden" {
  name              = "/ecs/${var.project_name}/vaultwarden"
  retention_in_days = 30

  tags = { Name = "${var.project_name}-vaultwarden" }
}

# --- ALB Target Group & Listener Rule ---

resource "aws_lb_target_group" "vaultwarden" {
  name        = "${var.project_name}-vaultwarden"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/alive"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "${var.project_name}-vaultwarden" }
}

resource "aws_lb_listener_rule" "vaultwarden" {
  listener_arn = var.https_listener_arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vaultwarden.arn
  }

  condition {
    host_header {
      values = ["vault.${var.domain_name}"]
    }
  }
}

# --- Route53 ---

resource "aws_route53_record" "vaultwarden" {
  zone_id = var.domain_zone_id
  name    = "vault.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# --- ECS Task Definition ---

resource "aws_ecs_task_definition" "vaultwarden" {
  family                   = "${var.project_name}-vaultwarden"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "vaultwarden"
    image     = var.vaultwarden_image
    essential = true

    portMappings = [{
      containerPort = 80
      hostPort      = 80
      protocol      = "tcp"
    }]

    entryPoint = ["/bin/sh", "-c"]
    command    = ["export DATABASE_URL=postgresql://vaultwarden:$DB_PASSWORD@${var.db_host}/vaultwarden?sslmode=require && exec /start.sh"]

    environment = [
      { name = "DOMAIN", value = "https://vault.${var.domain_name}" },
      { name = "ROCKET_PORT", value = "80" },
      { name = "SIGNUPS_ALLOWED", value = "false" },
      { name = "SSO_ENABLED", value = "true" },
      { name = "SSO_CLIENT_ID", value = "vaultwarden" },
      { name = "SSO_AUTHORITY", value = "${var.authentik_url}/application/o/vaultwarden/" },
    ]

    secrets = [
      {
        name      = "DB_PASSWORD"
        valueFrom = var.vaultwarden_db_password_arn
      },
      {
        name      = "ADMIN_TOKEN"
        valueFrom = var.admin_token_arn
      },
      {
        name      = "SSO_CLIENT_SECRET"
        valueFrom = aws_secretsmanager_secret.sso_client_secret.arn
      },
    ]

    mountPoints = [{
      containerPath = "/data"
      sourceVolume  = "vaultwarden-data"
      readOnly      = false
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.vaultwarden.name
        "awslogs-region"        = data.aws_region.current.id
        "awslogs-stream-prefix" = "vaultwarden"
      }
    }
  }])

  volume {
    name = "vaultwarden-data"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.data.id
        iam             = "DISABLED"
      }
    }
  }

  tags = { Name = "${var.project_name}-vaultwarden" }
}

# --- Authentik SSO ---

data "authentik_flow" "default_authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_invalidation" {
  slug = "default-invalidation-flow"
}

data "authentik_certificate_key_pair" "default" {
  name = "authentik Self-signed Certificate"
}

data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

resource "authentik_property_mapping_provider_scope" "email_verified" {
  name       = "email-verified-vaultwarden"
  scope_name = "email"
  expression = <<-EOF
    return {
      "email": request.user.email,
      "email_verified": True,
    }
  EOF
}

data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

resource "authentik_provider_oauth2" "vaultwarden" {
  name      = "Vaultwarden"
  client_id = "vaultwarden"

  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.default.id

  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    authentik_property_mapping_provider_scope.email_verified.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://vault.${var.domain_name}/identity/connect/oidc-signin"
    }
  ]
}

resource "authentik_application" "vaultwarden" {
  name              = "Vaultwarden"
  slug              = "vaultwarden"
  protocol_provider = authentik_provider_oauth2.vaultwarden.id
}

resource "aws_secretsmanager_secret" "sso_client_secret" {
  name                    = "${var.project_name}/vaultwarden/sso_client_secret"
  recovery_window_in_days = 0

  tags = { Name = "${var.project_name}/vaultwarden/sso_client_secret" }
}

resource "aws_secretsmanager_secret_version" "sso_client_secret" {
  secret_id     = aws_secretsmanager_secret.sso_client_secret.id
  secret_string = authentik_provider_oauth2.vaultwarden.client_secret
}

# --- ECS Service ---

resource "aws_ecs_service" "vaultwarden" {
  name                   = "${var.project_name}-vaultwarden"
  cluster                = var.ecs_cluster_id
  task_definition        = aws_ecs_task_definition.vaultwarden.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = var.private_subnets
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.vaultwarden.arn
    container_name   = "vaultwarden"
    container_port   = 80
  }

  depends_on = [aws_lb_listener_rule.vaultwarden]

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = { Name = "${var.project_name}-vaultwarden" }
}
