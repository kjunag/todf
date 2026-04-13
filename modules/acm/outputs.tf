output "certificate_arn" {
  description = "ARN wygenerowanego certyfikatu SSL"
  value       = aws_acm_certificate_validation.main.certificate_arn
}