resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb"
  description = "ALB public HTTP HTTPS traffic"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "Towards authentik containers"
    from_port       = 9000
    to_port         = 9000
    protocol        = "tcp"
    security_groups = [aws_security_group.authentik.id]
  }

  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_security_group" "authentik" {
  name        = "${var.project_name}-app"
  description = "Authentik containers (server + worker)"
  vpc_id      = var.vpc_id

  egress {
    description = "All output traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-app" }
}

resource "aws_security_group_rule" "authentik_from_alb" {
  description              = "Ruch z ALB"
  type                     = "ingress"
  from_port                = 9000
  to_port                  = 9000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.authentik.id
  source_security_group_id = aws_security_group.alb.id
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds"
  description = "RDS PostgreSQL access only from authentik"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from containers"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.authentik.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-rds" }
}


resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project_name}/db-password"
  recovery_window_in_days = 0 # natychmiastowe usunięcie przy destroy

  tags = { Name = "${var.project_name}/db-password" }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = "authentik"
    password = random_password.db.result
  })
}

resource "random_password" "db" {
  length           = 64
  special          = true
  override_special = "!#$%&*()-_=+[]{}|;:,.<>?"
}

resource "aws_secretsmanager_secret" "secret_key" {
  name                    = "${var.project_name}/secret-key"
  recovery_window_in_days = 0

  tags = { Name = "${var.project_name}/secret-key" }
}

resource "aws_secretsmanager_secret_version" "secret_key" {
  secret_id     = aws_secretsmanager_secret.secret_key.id
  secret_string = random_password.secret_key.result
}

resource "random_password" "secret_key" {
  length           = 64
  special          = true
  override_special = "!#$%&*()-_=+[]{}|;:,.<>?"
}


resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db"
  subnet_ids = var.private_subnets

  tags = { Name = "${var.project_name}-db" }
}

resource "aws_db_instance" "main" {
  identifier        = "${var.project_name}-db"
  engine            = "postgres"
  engine_version    = var.db_version
  instance_class    = "db.${var.db_instance_type}"
  db_name           = "authentik"
  username          = "authentik"
  password          = random_password.db.result
  allocated_storage = var.db_storage
  storage_type      = "gp2"

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az               = false
  publicly_accessible    = false
  copy_tags_to_snapshot  = true
  skip_final_snapshot    = false
  final_snapshot_identifier = "${var.project_name}-db-final"

  tags = { Name = "${var.project_name}-db" }
}