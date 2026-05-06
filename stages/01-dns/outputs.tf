output "zone_id" {
  description = "Route53 Hosted Zone ID"
  value       = module.dns.zone_id
}

output "name_servers" {
  description = "Nameservers to configure at your registrar"
  value       = module.dns.name_servers
}
