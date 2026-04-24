variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Common project name"
  type        = string
  default     = "todf"
}

variable "db_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "16.4"
}

variable "db_storage" {
  description = "Disk size for PostgreSQL DB (GB)"
  type        = number
  default     = 20
}

variable "db_instance_type" {
  description = "RDS instance type"
  type        = string
  default     = "db.t4g.micro"
}
