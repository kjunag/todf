output "name_servers" {
  description = "Adresy serwerów DNS do wpisania w Porkbun"
  value       = aws_route53_zone.main.name_servers
}