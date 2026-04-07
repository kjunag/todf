variable "aws_region" {
  description = "Region AWS"
  type        = string
  default     = "us-east-1"
}
variable "project_name" {
    description = "Common name of freedom project"
    type = string
    default = "TODF"
}
variable "root_domain" {
  description = "Root domain of whole project"
  type = string
  default = "todf.mom"
}