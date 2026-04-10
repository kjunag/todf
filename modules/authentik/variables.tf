variable "project_name" {
  type = string
  description = "Project name"
}
variable "vpc_id" {
  type = string
  description = "ID of main VPC"
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

variable "private_subnets" {
  description = "List of private subnets in VPC"
  type = list(any)
}

variable "efs_id" {
  description = "ID of project's main EFS"
  type = string
}