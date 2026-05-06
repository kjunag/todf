output "nlb_dns_name" {
  description = "NLB DNS name (set as mail.domain MX target)"
  value       = aws_lb.nlb.dns_name
}

output "webmail_url" {
  value = "https://webmail.${var.domain_name}"
}

output "route53_access_key_id" {
  value = aws_iam_access_key.route53_dns.id
}

output "route53_secret_access_key" {
  value     = aws_iam_access_key.route53_dns.secret
  sensitive = true
}
