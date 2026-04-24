module "dns" {
  source      = "../../modules/dns"
  root_domain = var.root_domain
}
