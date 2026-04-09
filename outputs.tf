output "vpc_id" {
  description = "ID głównego VPC (wymagane dla Security Group aplikacji i RDS)"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Lista podsieci publicznych (na wypadek dodatkowych usług zewn.)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Lista podsieci prywatnych (wymagane dla kontenerów ECS, RDS i ElastiCache)"
  value       = aws_subnet.private[*].id
}


output "ecs_cluster_id" {
  description = "ID klastra ECS (wymagane do uruchomienia usług aplikacji)"
  value       = aws_ecs_cluster.main.id
}

output "ecs_cluster_name" {
  description = "Nazwa klastra ECS"
  value       = aws_ecs_cluster.main.name
}

output "ecs_execution_role_arn" {
  description = "ARN roli technicznej dla ECS (wymagane do pobierania obrazów i logowania)"
  value       = aws_iam_role.ecs_task_execution_role.arn
}


output "efs_shared_id" {
  description = "ID wspólnego dysku EFS (wymagane dla zasobów EFS Access Point w apkach)"
  value       = aws_efs_file_system.shared.id
}

output "efs_security_group_id" {
  description = "ID Security Group dla EFS (przydatne do precyzyjnych reguł sieciowych)"
  value       = aws_security_group.efs.id
}