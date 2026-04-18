output "zone_id" {
  description = "Route53 Hosted Zone ID"
  value       = aws_route53_zone.main.zone_id
}

output "name_servers" {
  description = "DNS nameservers to configure at your registrar"
  value       = aws_route53_zone.main.name_servers
}