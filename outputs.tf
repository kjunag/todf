output "vpc_id" {
  description = "Main VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "ecs_cluster_id" {
  description = "ECS cluster ID"
  value       = aws_ecs_cluster.main.id
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_execution_role_arn" {
  description = "ECS task execution role ARN"
  value       = aws_iam_role.ecs_task_execution_role.arn
}

output "efs_shared_id" {
  description = "Shared EFS file system ID"
  value       = aws_efs_file_system.shared.id
}

output "efs_security_group_id" {
  description = "EFS security group ID"
  value       = aws_security_group.efs.id
}

output "route53_nameservers" {
  description = "Route53 nameservers - set as NS records at your registrar"
  value       = module.dns.name_servers
}

output "authentik_url" {
  description = "Authentik admin panel URL"
  value       = "https://auth.${var.root_domain}"
}

output "authentik_admin_password" {
  description = "akadmin bootstrap password (also in Secrets Manager: todf/authentik-bootstrap-password)"
  value       = random_password.authentik_bootstrap.result
  sensitive   = true
}

output "alb_dns" {
  description = "Public ALB DNS name"
  value       = module.alb.load_balancer_dns
}
