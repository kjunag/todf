output "load_balancer_dns" {
  description = "Public DNS name of the load balancer"
  value       = aws_lb.main.dns_name
}

output "load_balancer_zone_id" {
  description = "ALB hosted zone ID for Route53 ALIAS records"
  value       = aws_lb.main.zone_id
}

output "alb_sg_id" {
  description = "ALB security group ID"
  value       = aws_security_group.alb.id
}

output "https_listener_arn" {
  description = "HTTPS listener ARN for app routing rules"
  value       = aws_lb_listener.https.arn
}
