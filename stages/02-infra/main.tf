data "aws_availability_zones" "available" {
  state = "available"
}

# --- VPC & Networking ---

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project_name}/vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}/igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet("10.0.0.0/16", 2, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}/public-${count.index + 1}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 2, count.index + 2)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "${var.project_name}/private-${count.index + 1}" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}/nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags       = { Name = "${var.project_name}/nat" }
  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}/rt-public" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project_name}/rt-private" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Security Groups ---

resource "aws_security_group" "efs" {
  name        = "${var.project_name}-efs-sg"
  description = "Allows NFS traffic to shared EFS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "NFS from entire VPC"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-efs-sg" }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds"
  description = "PostgreSQL access from VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-rds" }
}

resource "aws_security_group" "redis" {
  name        = "${var.project_name}-redis-sg"
  description = "Redis access from VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Redis from VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-redis" }
}

# --- EFS ---

resource "aws_efs_file_system" "shared" {
  creation_token   = "${var.project_name}-shared-efs"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"

  tags = { Name = "${var.project_name}-shared-efs" }
}

resource "aws_efs_mount_target" "shared" {
  count           = length(aws_subnet.private)
  file_system_id  = aws_efs_file_system.shared.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

# --- RDS PostgreSQL ---

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${var.project_name}-db" }
}

resource "random_password" "db" {
  length           = 64
  special          = true
  override_special = "!#$%&*()-_=+[]{}|;:,.<>?"
}

resource "aws_db_instance" "main" {
  identifier             = "${var.project_name}-db"
  engine                 = "postgres"
  engine_version         = var.db_version
  instance_class         = var.db_instance_type
  allocated_storage      = var.db_storage
  storage_type           = "gp3"
  db_name                = "authentik"
  username               = "authentik"
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  skip_final_snapshot       = true
  final_snapshot_identifier = "${var.project_name}-db-final"
  copy_tags_to_snapshot     = true

  tags = { Name = "${var.project_name}-db" }
}

# --- ElastiCache Redis ---

resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.project_name}-redis-subnet"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${var.project_name}-redis-subnet" }
}

resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${var.project_name}-redis"
  engine               = "redis"
  node_type            = "cache.t4g.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.1"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.redis.id]

  tags = { Name = "${var.project_name}-redis" }
}

# --- ECS Cluster & IAM ---

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_secrets_access" {
  name = "${var.project_name}-ecs-secrets"
  role = aws_iam_role.ecs_task_execution.id

  # Wildcard allows stage 03 to add new secrets without updating this policy
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = ["arn:aws:secretsmanager:*:*:secret:${var.project_name}/*"]
    }]
  })
}

# --- Secrets Manager ---

resource "random_password" "secret_key" {
  length           = 64
  special          = true
  override_special = "!#$%&*()-_=+[]{}|;:,.<>?"
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project_name}/db-password"
  recovery_window_in_days = 0

  tags = { Name = "${var.project_name}/db-password" }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = "authentik"
    password = random_password.db.result
  })
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

resource "random_password" "authentik_bootstrap" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "authentik_bootstrap_password" {
  name                    = "${var.project_name}/authentik-bootstrap-password"
  recovery_window_in_days = 0

  tags = { Name = "${var.project_name}/authentik-bootstrap-password" }
}

resource "aws_secretsmanager_secret_version" "authentik_bootstrap_password" {
  secret_id     = aws_secretsmanager_secret.authentik_bootstrap_password.id
  secret_string = random_password.authentik_bootstrap.result
}

resource "random_password" "nextcloud_db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "nextcloud_db_password" {
  name                    = "${var.project_name}/nextcloud-db-password"
  recovery_window_in_days = 0

  tags = { Name = "${var.project_name}/nextcloud-db-password" }
}

resource "aws_secretsmanager_secret_version" "nextcloud_db_password" {
  secret_id     = aws_secretsmanager_secret.nextcloud_db_password.id
  secret_string = random_password.nextcloud_db.result
}

resource "random_password" "stalwart_db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "stalwart_db_password" {
  name                    = "${var.project_name}/stalwart-db-password"
  recovery_window_in_days = 0

  tags = { Name = "${var.project_name}/stalwart-db-password" }
}

resource "aws_secretsmanager_secret_version" "stalwart_db_password" {
  secret_id     = aws_secretsmanager_secret.stalwart_db_password.id
  secret_string = random_password.stalwart_db.result
}

# Resend SMTP relay credentials — set the API key after obtaining it from resend.com
resource "aws_secretsmanager_secret" "resend_smtp" {
  name                    = "${var.project_name}/resend-smtp"
  recovery_window_in_days = 0

  tags = { Name = "${var.project_name}/resend-smtp" }
}

resource "aws_secretsmanager_secret_version" "resend_smtp" {
  secret_id = aws_secretsmanager_secret.resend_smtp.id
  secret_string = jsonencode({
    username = "resend"
    password = "REPLACE_WITH_RESEND_API_KEY"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
