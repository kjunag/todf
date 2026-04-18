output "app_sg_id" {
  description = "Authentik application security group ID"
  value       = aws_security_group.app.id
}

output "server_service_name" {
  description = "ECS service name for Authentik server"
  value       = aws_ecs_service.server.name
}

output "worker_service_name" {
  description = "ECS service name for Authentik worker"
  value       = aws_ecs_service.worker.name
}
