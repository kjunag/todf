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

variable "root_domain" {
  description = "Root domain of the project"
  type        = string
  default     = "todf.mom"
}
