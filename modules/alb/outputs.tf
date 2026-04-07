output "load_balancer_dns" {
  description = "Publiczny adres DNS load balancera – skieruj tutaj swój rekord DNS"
  value       = aws_lb.main.dns_name
}

output "load_balancer_zone_id" {
  description = "Hosted Zone ID ALB (potrzebne do rekordu Route53 typu ALIAS)"
  value       = aws_lb.main.zone_id
}