output "authentik_url" {
  value = "https://auth.${var.root_domain}"
}

output "authentik_api_token_secret_arn" {
  value = module.authentik.authentik_api_token_secret_arn
}
