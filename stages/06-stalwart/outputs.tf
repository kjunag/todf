output "webmail_url" {
  value = "https://webmail.${var.root_domain}"
}

output "nlb_dns_name" {
  description = "NLB DNS — use for SPF/PTR verification"
  value       = module.stalwart.nlb_dns_name
}

output "route53_access_key_id" {
  value = module.stalwart.route53_access_key_id
}

output "route53_secret_access_key" {
  value     = module.stalwart.route53_secret_access_key
  sensitive = true
}
