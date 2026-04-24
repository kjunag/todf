variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnets" {
  type = list(string)
}

variable "public_subnets" {
  type        = list(string)
  description = "Public subnets for the NLB"
}

variable "ecs_cluster_id" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "efs_id" {
  type = string
}

variable "db_host" {
  type = string
}

variable "stalwart_db_password_arn" {
  type        = string
  description = "Secrets Manager ARN for stalwart DB password (plain string)"
}

variable "alb_sg_id" {
  type        = string
  description = "ALB security group ID — for adding HTTPS admin UI rule"
}

variable "https_listener_arn" {
  type        = string
  description = "HTTPS ALB listener ARN for admin UI routing"
}

variable "alb_dns_name" {
  type        = string
  description = "ALB DNS name for webmail Route53 alias"
}

variable "alb_zone_id" {
  type        = string
  description = "ALB hosted zone ID for Route53 alias"
}

variable "domain_name" {
  type        = string
  description = "Root domain (e.g. todf.mom)"
}

variable "domain_zone_id" {
  type        = string
  description = "Route53 hosted zone ID"
}

variable "smtp_relay_host" {
  type        = string
  description = "External SMTP relay hostname (e.g. smtp.brevo.com)"
  default     = ""
}

variable "smtp_relay_port" {
  type        = number
  description = "External SMTP relay port"
  default     = 587
}

variable "smtp_relay_credentials_arn" {
  type        = string
  description = "Secrets Manager ARN for SMTP relay credentials (JSON with username/password). Empty string disables relay."
  default     = ""
}

variable "stalwart_image" {
  type    = string
  default = "stalwartlabs/stalwart:latest"
}

variable "stalwart_recovery_password" {
  type        = string
  description = "Pins the bootstrap recovery admin password via STALWART_RECOVERY_ADMIN env var. Set once to avoid random passwords on each restart."
  default     = ""
  sensitive   = true
}
