module "dns" {
  source      = "./modules/dns"
  root_domain = var.root_domain
}

resource "aws_acm_certificate" "main" {
  domain_name               = "*.${var.root_domain}"
  subject_alternative_names = [var.root_domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.project_name}-cert" }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = module.dns.zone_id
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

resource "aws_route53_record" "authentik" {
  zone_id = module.dns.zone_id
  name    = "auth.${var.root_domain}"
  type    = "A"

  alias {
    name                   = module.alb.load_balancer_dns
    zone_id                = module.alb.load_balancer_zone_id
    evaluate_target_health = true
  }
}
