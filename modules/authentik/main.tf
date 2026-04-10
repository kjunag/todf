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


resource "aws_efs_access_point" "authentik_data" {
  file_system_id = var.efs_id
  posix_user {
    uid = 1000
    gid = 1000
  }
  root_directory {
    path = "/authentik/data"
    creation_info {
      owner_uid = 1000
      owner_gid = 1000
      permissions = "755"
    }
  }
  tags = { Name = "authentik-data-vol" }
}
resource "aws_efs_access_point" "authentik_media" {
  file_system_id = var.efs_id
  posix_user {
    uid = 1000
    gid = 1000
  }
  root_directory {
    path = "/authentik/media"
    creation_info {
      owner_uid = 1000
      owner_gid = 1000
      permissions = "755"
    }
  }
  tags = { Name = "authentik-media-vol" }
}
