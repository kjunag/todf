variable "aws_region" {
  description = "Region AWS"
  type        = string
  default     = "us-east-1"
}
variable "project_name" {
    description = "Common name of freedom project"
    type = string
    default = "todf"
}
variable "root_domain" {
  description = "Root domain of whole project"
  type = string
  default = "todf.mom"
}
variable "db_version" {
  description = "Version of PGSQL"
  type = string
  default = "17"
}
variable "db_storage" {
  description = "Disk size for PgSQL DB"
  type = number
  default = 10
}
variable "db_instance_type" {
  description = "RDS instance type"
  type = string
  default = "m5.large"
}