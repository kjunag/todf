variable "domain_name" {
  description = "Główna nazwa domeny"
  type        = string
}

variable "zone_id" {
  description = "ID strefy w Route53 do walidacji certyfikatu"
  type        = string
}