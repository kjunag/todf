output "service_name" {
  value = aws_ecs_service.vaultwarden.name
}

output "security_group_id" {
  value = aws_security_group.app.id
}
