# Networking
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

# ECS
output "ecs_cluster_id" {
  value = aws_ecs_cluster.main.id
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_execution_role_arn" {
  value = aws_iam_role.ecs_task_execution.arn
}

# Storage & databases
output "efs_id" {
  value = aws_efs_file_system.shared.id
}

output "rds_address" {
  value = aws_db_instance.main.address
}

output "redis_endpoint" {
  value = aws_elasticache_cluster.redis.cache_nodes[0].address
}

# Security groups
output "efs_sg_id" {
  value = aws_security_group.efs.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

# Secrets ARNs
output "db_secret_arn" {
  value = aws_secretsmanager_secret.db_password.arn
}

output "secret_key_arn" {
  value = aws_secretsmanager_secret.secret_key.arn
}

output "authentik_bootstrap_password_arn" {
  value = aws_secretsmanager_secret.authentik_bootstrap_password.arn
}

output "nextcloud_db_password_arn" {
  value = aws_secretsmanager_secret.nextcloud_db_password.arn
}

output "stalwart_db_password_arn" {
  value = aws_secretsmanager_secret.stalwart_db_password.arn
}

output "resend_smtp_secret_arn" {
  value = aws_secretsmanager_secret.resend_smtp.arn
}

# Sensitive outputs used for initial setup
output "authentik_bootstrap_password" {
  value     = random_password.authentik_bootstrap.result
  sensitive = true
}
