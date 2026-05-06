output "certificate_arn" {
  value = aws_acm_certificate_validation.main.certificate_arn
}

output "alb_sg_id" {
  value = module.alb.alb_sg_id
}

output "https_listener_arn" {
  value = module.alb.https_listener_arn
}

output "alb_dns_name" {
  value = module.alb.load_balancer_dns
}

output "alb_zone_id" {
  value = module.alb.load_balancer_zone_id
}

output "alb_arn" {
  value = module.alb.alb_arn
}
