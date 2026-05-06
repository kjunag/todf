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

variable "tf_state_bucket" {
  type    = string
  default = "todf-tfstate-bucket"
}

variable "tf_state_lock_table" {
  type    = string
  default = "todf-tfstate-lock"
}
