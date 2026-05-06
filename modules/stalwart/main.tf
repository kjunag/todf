data "aws_region" "current" {}

# --- Security Groups ---

resource "aws_security_group" "task" {
  name        = "${var.project_name}-stalwart-task"
  description = "Stalwart mail server containers"
  vpc_id      = var.vpc_id

  # Internal ports — NLB forwards standard ports to these
  ingress {
    description = "SMTP internal"
    from_port   = 2025
    to_port     = 2025
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Submission internal"
    from_port   = 2587
    to_port     = 2587
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }


  ingress {
    description = "IMAP internal"
    from_port   = 2143
    to_port     = 2143
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "IMAPS internal"
    from_port   = 2993
    to_port     = 2993
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Admin UI / JMAP from ALB only
  ingress {
    description     = "Admin UI from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [var.alb_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-stalwart-task" }
}

resource "aws_security_group_rule" "alb_egress_stalwart" {
  type                     = "egress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = var.alb_sg_id
  source_security_group_id = aws_security_group.task.id
  description              = "Traffic to Stalwart admin UI"
}

# --- NLB (Network Load Balancer for mail ports) ---

resource "aws_lb" "nlb" {
  name                       = "${var.project_name}-mail-nlb"
  internal                   = false
  load_balancer_type         = "network"
  subnets                    = var.public_subnets
  enable_deletion_protection = false

  tags = { Name = "${var.project_name}-mail-nlb" }
}

# Target groups — one per mail port

resource "aws_lb_target_group" "smtp" {
  name        = "${var.project_name}-smtp"
  port        = 2025
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "TCP"
    port                = "2025"
    healthy_threshold   = 2
    unhealthy_threshold = 10
    interval            = 30
  }

  tags = { Name = "${var.project_name}-smtp" }
  lifecycle { create_before_destroy = true }
}

resource "aws_lb_target_group" "submission" {
  name        = "${var.project_name}-submission"
  port        = 2587
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "TCP"
    port                = "2587"
    healthy_threshold   = 2
    unhealthy_threshold = 10
    interval            = 30
  }

  tags = { Name = "${var.project_name}-submission" }
  lifecycle { create_before_destroy = true }
}


resource "aws_lb_target_group" "imap" {
  name        = "${var.project_name}-imap"
  port        = 2143
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "TCP"
    port                = "2143"
    healthy_threshold   = 2
    unhealthy_threshold = 10
    interval            = 30
  }

  tags = { Name = "${var.project_name}-imap" }
  lifecycle { create_before_destroy = true }
}

resource "aws_lb_target_group" "imaps" {
  name        = "${var.project_name}-imaps"
  port        = 2993
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "TCP"
    port                = "2993"
    healthy_threshold   = 2
    unhealthy_threshold = 10
    interval            = 30
  }

  tags = { Name = "${var.project_name}-imaps" }
  lifecycle { create_before_destroy = true }
}

# NLB Listeners

resource "aws_lb_listener" "smtp" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 25
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.smtp.arn
  }
}

resource "aws_lb_listener" "submission" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 587
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.submission.arn
  }
}


resource "aws_lb_listener" "imap" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 143
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.imap.arn
  }
}

resource "aws_lb_listener" "imaps" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 993
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.imaps.arn
  }
}

# --- ALB rule for admin UI ---

resource "aws_lb_target_group" "admin" {
  name        = "${var.project_name}-stalwart-admin"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/admin/"
    port                = "8080"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    matcher             = "200-499"
  }

  tags = { Name = "${var.project_name}-stalwart-admin" }
}

resource "aws_lb_listener_rule" "admin" {
  listener_arn = var.https_listener_arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.admin.arn
  }

  condition {
    host_header {
      values = ["webmail.${var.domain_name}"]
    }
  }
}

# --- EFS Access Point ---

resource "aws_efs_access_point" "stalwart" {
  file_system_id = var.efs_id

  posix_user {
    uid = 2000
    gid = 2000
  }

  root_directory {
    path = "/stalwart"
    creation_info {
      owner_uid   = 2000
      owner_gid   = 2000
      permissions = "755"
    }
  }

  tags = { Name = "${var.project_name}-stalwart-data" }
}

# --- EFS Permission Fix ---

resource "aws_ecs_task_definition" "efs_chown" {
  family                   = "${var.project_name}-stalwart-efs-chown"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = var.execution_role_arn

  volume {
    name = "efs-root"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      root_directory     = "/"
      transit_encryption = "ENABLED"
    }
  }

  container_definitions = jsonencode([{
    name      = "chown"
    image     = "busybox"
    essential = true
    command   = ["sh", "-c", "mkdir -p /efs/stalwart/etc /efs/stalwart/data && chown -R 2000:2000 /efs/stalwart && chmod -R 755 /efs/stalwart && echo 'EFS permissions fixed'"]
    mountPoints = [{
      sourceVolume  = "efs-root"
      containerPath = "/efs"
      readOnly      = false
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.stalwart.name
        "awslogs-region"        = data.aws_region.current.id
        "awslogs-stream-prefix" = "efs-chown"
      }
    }
  }])
}

resource "null_resource" "efs_chown" {
  triggers = {
    access_point_id = aws_efs_access_point.stalwart.id
  }

  provisioner "local-exec" {
    command = <<EOT
      TASK_ARN=$(aws ecs run-task \
        --cluster ${var.ecs_cluster_id} \
        --task-definition ${aws_ecs_task_definition.efs_chown.arn} \
        --launch-type FARGATE \
        --network-configuration 'awsvpcConfiguration={subnets=["${var.private_subnets[0]}"],securityGroups=["${aws_security_group.task.id}"],assignPublicIp=DISABLED}' \
        --region ${data.aws_region.current.id} \
        --query 'tasks[0].taskArn' --output text)
      echo "Waiting for EFS chown task: $TASK_ARN"
      aws ecs wait tasks-stopped --cluster ${var.ecs_cluster_id} --tasks "$TASK_ARN" --region ${data.aws_region.current.id}
      EXIT_CODE=$(aws ecs describe-tasks --cluster ${var.ecs_cluster_id} --tasks "$TASK_ARN" --query 'tasks[0].containers[0].exitCode' --output text)
      echo "EFS chown exit code: $EXIT_CODE"
      test "$EXIT_CODE" = "0"
    EOT
  }

  depends_on = [aws_efs_access_point.stalwart, aws_security_group.task]
}

# --- CloudWatch Logs ---

resource "aws_cloudwatch_log_group" "stalwart" {
  name              = "/ecs/${var.project_name}/stalwart"
  retention_in_days = 30

  tags = { Name = "${var.project_name}-stalwart" }
}

# --- IAM Task Role (SSM exec for debugging) ---

resource "aws_iam_role" "task" {
  name = "${var.project_name}-stalwart-task-role"

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
  name = "${var.project_name}-stalwart-exec-command"
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

resource "aws_iam_user" "route53_dns" {
  name = "${var.project_name}-stalwart-dns"
  tags = { Name = "${var.project_name}-stalwart-dns" }
}

resource "aws_iam_user_policy" "route53_dns" {
  name = "${var.project_name}-stalwart-route53"
  user = aws_iam_user.route53_dns.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.domain_zone_id}"
      },
      {
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = "arn:aws:route53:::change/*"
      }
    ]
  })
}

resource "aws_iam_access_key" "route53_dns" {
  user = aws_iam_user.route53_dns.name
}

resource "aws_iam_role_policy" "task_route53" {
  name = "${var.project_name}-stalwart-route53"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.domain_zone_id}"
      },
      {
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = "arn:aws:route53:::change/*"
      }
    ]
  })
}

# --- ECS Task Definition ---

locals {
  relay_env = var.smtp_relay_host != "" ? [
    { name = "SMTP_RELAY_HOST", value = var.smtp_relay_host },
    { name = "SMTP_RELAY_PORT", value = tostring(var.smtp_relay_port) },
  ] : []

  relay_secrets = var.smtp_relay_credentials_arn != "" ? [
    { name = "SMTP_RELAY_USERNAME", valueFrom = "${var.smtp_relay_credentials_arn}:username::" },
    { name = "SMTP_RELAY_PASSWORD", valueFrom = "${var.smtp_relay_credentials_arn}:password::" },
  ] : []
}

resource "aws_ecs_task_definition" "stalwart" {
  family                   = "${var.project_name}-stalwart"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  volume {
    name = "stalwart-data"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.stalwart.id
        iam             = "DISABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "stalwart"
    image     = var.stalwart_image
    essential = true
    user      = "2000:2000"

    portMappings = [
      { containerPort = 2025, hostPort = 2025, protocol = "tcp" },
      { containerPort = 2587, hostPort = 2587, protocol = "tcp" },
      { containerPort = 2143, hostPort = 2143, protocol = "tcp" },
      { containerPort = 2993, hostPort = 2993, protocol = "tcp" },
      { containerPort = 8080, hostPort = 8080, protocol = "tcp" },
    ]

    environment = concat([
      { name = "DB_HOST",             value = var.db_host },
      { name = "DB_NAME",             value = "stalwart" },
      { name = "DB_USER",             value = "stalwart" },
      { name = "DOMAIN_NAME",         value = var.domain_name },
      { name = "STALWART_HTTPS_PORT", value = "443" },
    ], local.relay_env, var.stalwart_recovery_password != "" ? [
      { name = "STALWART_RECOVERY_ADMIN", value = "admin:${var.stalwart_recovery_password}" }
    ] : [])

    secrets = concat([
      { name = "DB_PASSWORD", valueFrom = var.stalwart_db_password_arn },
    ], local.relay_secrets)

    mountPoints = [
      {
        sourceVolume  = "stalwart-data"
        containerPath = "/etc/stalwart"
        readOnly      = false
      },
      {
        sourceVolume  = "stalwart-data"
        containerPath = "/var/lib/stalwart"
        readOnly      = false
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.stalwart.name
        "awslogs-region"        = data.aws_region.current.id
        "awslogs-stream-prefix" = "stalwart"
      }
    }
  }])

  tags = { Name = "${var.project_name}-stalwart" }
}

# --- ECS Service ---

resource "aws_ecs_service" "stalwart" {
  name                              = "${var.project_name}-stalwart"
  cluster                           = var.ecs_cluster_id
  task_definition                   = aws_ecs_task_definition.stalwart.arn
  desired_count                     = 1
  launch_type                       = "FARGATE"
  enable_execute_command            = true
  health_check_grace_period_seconds = 180

  network_configuration {
    subnets          = var.private_subnets
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.smtp.arn
    container_name   = "stalwart"
    container_port   = 2025
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.submission.arn
    container_name   = "stalwart"
    container_port   = 2587
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.imap.arn
    container_name   = "stalwart"
    container_port   = 2143
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.imaps.arn
    container_name   = "stalwart"
    container_port   = 2993
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.admin.arn
    container_name   = "stalwart"
    container_port   = 8080
  }

  depends_on = [
    aws_lb_listener.smtp,
    aws_lb_listener.submission,
    aws_lb_listener.imap,
    aws_lb_listener.imaps,
    aws_lb_listener_rule.admin,
    null_resource.efs_chown,
  ]

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = { Name = "${var.project_name}-stalwart" }
}

# --- DNS Records ---

resource "aws_route53_record" "mail_a" {
  zone_id = var.domain_zone_id
  name    = "mail.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.nlb.dns_name
    zone_id                = aws_lb.nlb.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "mx" {
  zone_id = var.domain_zone_id
  name    = var.domain_name
  type    = "MX"
  ttl     = 300
  records = ["10 mail.${var.domain_name}"]
}

resource "aws_route53_record" "spf" {
  zone_id = var.domain_zone_id
  name    = var.domain_name
  type    = "TXT"
  ttl     = 300
  records = ["v=spf1 mx ~all"]
}

resource "aws_route53_record" "dmarc" {
  zone_id = var.domain_zone_id
  name    = "_dmarc.${var.domain_name}"
  type    = "TXT"
  ttl     = 300
  records = ["v=DMARC1; p=quarantine; rua=mailto:postmaster@${var.domain_name}"]
}

resource "aws_route53_record" "webmail" {
  zone_id = var.domain_zone_id
  name    = "webmail.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}
