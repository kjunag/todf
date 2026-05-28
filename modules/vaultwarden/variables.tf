variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnets" {
  type = list(string)
}

variable "ecs_cluster_id" {
  type = string
}

variable "ecs_execution_role_arn" {
  type = string
}

variable "efs_id" {
  type = string
}

variable "db_host" {
  type = string
}

variable "vaultwarden_db_password_arn" {
  type = string
}

variable "admin_token_arn" {
  type = string
}

variable "alb_sg_id" {
  type = string
}

variable "https_listener_arn" {
  type = string
}

variable "alb_dns_name" {
  type = string
}

variable "alb_zone_id" {
  type = string
}

variable "domain_name" {
  type = string
}

variable "domain_zone_id" {
  type = string
}

variable "vaultwarden_image" {
  type    = string
  default = "vaultwarden/server:latest"
}

variable "authentik_url" {
  type = string
}
