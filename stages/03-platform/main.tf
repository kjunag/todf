data "terraform_remote_state" "dns" {
  backend = "s3"
  config = {
    bucket         = var.tf_state_bucket
    key            = "stages/01-dns/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = var.tf_state_lock_table
    encrypt        = true
  }
}

data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket         = var.tf_state_bucket
    key            = "stages/02-infra/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = var.tf_state_lock_table
    encrypt        = true
  }
}

# --- ACM Certificate ---

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
  zone_id         = data.terraform_remote_state.dns.outputs.zone_id
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

# --- ALB ---

module "alb" {
  source          = "../../modules/alb"
  project_name    = var.project_name
  public_subnets  = data.terraform_remote_state.infra.outputs.public_subnet_ids
  vpc_id          = data.terraform_remote_state.infra.outputs.vpc_id
  certificate_arn = aws_acm_certificate_validation.main.certificate_arn
}
