variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "todf"
}

variable "root_domain" {
  type    = string
  default = "todf.mom"
}

variable "authentik_version" {
  type    = string
  default = "2026.2.2"
}

variable "tf_state_bucket" {
  type    = string
  default = "todf-tfstate-bucket"
}

variable "tf_state_lock_table" {
  type    = string
  default = "todf-tfstate-lock"
}

variable "email_host" {
  type    = string
  default = "smtp.resend.com"
}

variable "email_port" {
  type    = number
  default = 587
}

variable "email_username" {
  type    = string
  default = "resend"
}

variable "email_from" {
  type    = string
  default = "noreply@todf.mom"
}
