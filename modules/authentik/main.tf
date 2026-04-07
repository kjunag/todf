resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb"
  description = "ALB – ruch publiczny HTTP/HTTPS"
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
    description     = "Do kontenerów Authentik"
    from_port       = 9000
    to_port         = 9000
    protocol        = "tcp"
    security_groups = [aws_security_group.authentik.id]
  }

  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_security_group" "authentik" {
  name        = "${var.project_name}-app"
  description = "Kontenery Authentik (server + worker)"
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
  description = "RDS PostgreSQL – dostęp tylko z Authentik"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL z kontenerów"
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

resource "aws_security_group" "efs" {
  name        = "${var.project_name}-efs"
  description = "EFS – dostęp tylko z Authentik"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "NFS z kontenerów"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.authentik.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-efs" }
}