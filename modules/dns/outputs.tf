output "name_servers" {
  description = "Adresy serwerów DNS do wpisania w Porkbun"
  value       = aws_route53_zone.main.name_servers
}
output "zone_id" {
  description = "ID strefy DNS w Route53"
  value       = aws_route53_zone.main.zone_id
}