
# SSO
data "authentik_flow" "default_authorization_flow" {
  slug = "default-provider-authorization-explicit-consent"
}

data "authentik_flow" "default_invalidation_flow" {
  slug = "default-provider-invalidation-flow"
}

data "authentik_certificate_key_pair" "default" {
  name = "authentik Self-signed Certificate" 
}

data "authentik_property_mapping_provider_scope" "oidc" {
  managed_list = [
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-profile"
  ]
}

resource "authentik_provider_oauth2" "synapse" {
  name               = "Synapse Matrix"
  client_id          = "synapse-matrix-client"
  client_type        = "confidential"
  authorization_flow = data.authentik_flow.default_authorization_flow.id
  
  # Nowe wymagane pole
  invalidation_flow  = data.authentik_flow.default_invalidation_flow.id
  signing_key        = data.authentik_certificate_key_pair.default.id

  property_mappings  = data.authentik_property_mapping_provider_scope.oidc.ids  

  # Zaktualizowana struktura przekierowań
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://matrix.${var.domain_name}/_synapse/client/oidc/callback"
    }
  ]
}

resource "authentik_application" "synapse" {
  name              = "Matrix"
  slug              = "matrix"
  protocol_provider = authentik_provider_oauth2.synapse.id
  meta_icon         = "https://upload.wikimedia.org/wikipedia/commons/7/7b/Matrix_logo.svg"
}

# --- SECRET DO OIDC ---

resource "aws_secretsmanager_secret" "synapse_oidc" {
  name                    = "${var.project_name}/synapse-oidc-secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "synapse_oidc" {
  secret_id     = aws_secretsmanager_secret.synapse_oidc.id
  secret_string = authentik_provider_oauth2.synapse.client_secret
}

# Pozwolenie roli ECS na odczyt nowego secretu
resource "aws_iam_role_policy" "synapse_oidc_secret_access" {
  name   = "${var.project_name}-synapse-oidc-secret"
  role   = split("/", var.execution_role_arn)[1]
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.synapse_oidc.arn]
    }]
  })
}


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
    path = "/synapse-v3"
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
      
      # --- PRZEJĘCIE KONTROLI NAD STARTEM ---
      entryPoint = ["/bin/sh", "-c"]

      command = [
        <<-EOT
        # 1. Sprawdzenie, czy to pierwsze uruchomienie. Jeśli tak, generujemy bazowy config pod Postgresa.
        if [ ! -f /data/homeserver.yaml ]; then
          /start.py generate
        fi

        # 2. Czyszczenie starych lub błędnych wpisów
        sed -i '/public_baseurl:/d' /data/homeserver.yaml
        sed -i '/enable_registration:/d' /data/homeserver.yaml
        sed -i '/enable_registration_without_verification:/d' /data/homeserver.yaml
        sed -i '/suppress_key_server_warning:/d' /data/homeserver.yaml
        sed -i '/oidc_providers:/,$d' /data/homeserver.yaml

        # 3. Dopisanie kluczowych parametrów
        echo "public_baseurl: \"https://matrix.${var.domain_name}/\"" >> /data/homeserver.yaml
        echo "enable_registration: true" >> /data/homeserver.yaml
        echo "enable_registration_without_verification: true" >> /data/homeserver.yaml
        echo "suppress_key_server_warning: true" >> /data/homeserver.yaml

        # 4. Wstrzyknięcie czystego, poprawnie sformatowanego bloku OIDC
        cat << EOF >> /data/homeserver.yaml
oidc_providers:
  - idp_id: authentik
    idp_name: "Zaloguj przez Authentik"
    issuer: "https://auth.${var.domain_name}/application/o/matrix/"
    client_id: "$OIDC_CLIENT_ID"
    client_secret: "$OIDC_CLIENT_SECRET"
    scopes: ["openid", "profile", "email"]
    user_mapping_provider:
      config:
        localpart_template: "{{ user.preferred_username | lower }}"
        display_name_template: "{{ user.name }}"
EOF

        # 5. Uruchomienie właściwego serwera
        exec /start.py
        EOT
      ]

      portMappings = [
        {
          containerPort = 8008
          protocol      = "tcp"
        }
      ]
      
      # Zostawiamy czyste zmienne bazowe, usuwając problematyczne SYNAPSE_CONFIG__
      environment = [
        { name = "SYNAPSE_SERVER_NAME", value = "matrix.${var.domain_name}" },
        { name = "SYNAPSE_REPORT_STATS", value = "no" },
        { name = "POSTGRES_DB", value = "synapse" },
        { name = "POSTGRES_USER", value = "synapse" },
        { name = "POSTGRES_HOST", value = var.db_host },
        { name = "REDIS_HOST", value = var.redis_endpoint },
        
        # Przekazujemy ID klienta z modułu Authentika bezpośrednio do powłoki kontenera
        { name = "OIDC_CLIENT_ID", value = authentik_provider_oauth2.synapse.client_id }
      ]
      
      secrets = [
        {
          name      = "POSTGRES_PASSWORD"
          valueFrom = var.db_secret_arn
        },
        # Przekazujemy sekretny klucz OIDC bezpośrednio do powłoki kontenera
        {
          name      = "OIDC_CLIENT_SECRET"
          valueFrom = aws_secretsmanager_secret.synapse_oidc.arn
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
          "awslogs-region"        = var.aws_region
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
  enable_execute_command = true

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

  depends_on = [aws_lb_listener_rule.synapse]
}


#resource "null_resource" "generate_synapse_config" {
#  triggers = {
#    # Odpal ponownie tylko jeśli zmieni się definicja taska
#    task_arn = aws_ecs_task_definition.synapse.arn
#  }
#
#  provisioner "local-exec" {
#    command = <<EOT
#      aws ecs run-task \
#        --cluster ${var.cluster_id} \
#        --task-definition ${aws_ecs_task_definition.synapse.arn} \
#        --launch-type FARGATE \
#        --network-configuration 'awsvpcConfiguration={subnets=["${var.subnets[0]}"],securityGroups=["${var.security_group_id}"]}' \
#        --overrides '{"containerOverrides": [{"name": "synapse", "command": ["generate"]}]}' \
#        --region ${var.aws_region}
#    EOT
#  }
#
#  # Musi poczekać aż powstanie Task Definition i Access Point EFS
#  depends_on = [
#    aws_ecs_task_definition.synapse,
#    aws_efs_access_point.synapse
#  ]
#}
