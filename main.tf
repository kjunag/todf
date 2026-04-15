data "aws_availability_zones" "available" {
  state = "available"
}

# module "dns" {
#   source = "./modules/dns"
# }

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
  count = 2 
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

  tags = { Name = "${var.project_name}/nat" }

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
  count = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.project_name}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

module "alb" {
  source         = "./modules/alb"
  project_name   = var.project_name
  public_subnets = aws_subnet.public[*].id
}


resource "aws_security_group" "efs" {
  name        = "${var.project_name}-efs-sg"
  description = "Pozwala na ruch NFS do wspolnego dysku EFS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "NFS z calego VPC"
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

resource "aws_efs_file_system" "shared" {
  creation_token = "${var.project_name}-shared-efs"
  encrypted      = true 

  performance_mode = "generalPurpose"
  throughput_mode  = "bursting" 

  tags = { Name = "${var.project_name}-shared-efs" }
}

resource "aws_efs_mount_target" "shared" {
  count           = 2
  file_system_id  = aws_efs_file_system.shared.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
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
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${var.project_name}-db" }
}
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds"
  description = "Dostęp do PgSQL z całego VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from VPC"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    cidr_blocks     = [aws_vpc.main.cidr_block] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-rds" }
}
resource "aws_rds_cluster" "main" {
  cluster_identifier      = "${var.project_name}-db"
  engine                  = "aurora-postgresql"
  engine_mode             = "provisioned"   # required for Serverless v2
  engine_version          = "16.4"          # nearest Aurora-Pg version to your current one
  database_name           = "authentik"
  master_username         = "authentik"
  master_password         = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.rds.id]

  serverlessv2_scaling_configuration {
    min_capacity = 0.5   # ACUs — scales to ~0 when idle (pauses billing)
    max_capacity = 4     # raise as you add apps; 1 ACU ≈ 2 GB RAM
  }

  skip_final_snapshot              = false
  final_snapshot_identifier        = "${var.project_name}-db-final"
  copy_tags_to_snapshot            = true

  tags = { Name = "${var.project_name}-db" }
}
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.project_name}-db-writer"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless"   # the magic value that enables SV2
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  tags = { Name = "${var.project_name}-db-writer" }
}
module "authentik" {
  source          = "./modules/authentik"
  project_name    = var.project_name
  vpc_id          = aws_vpc.main.id
  private_subnets = aws_subnet.private[*].id
  efs_id          = aws_efs_file_system.shared.id
}

