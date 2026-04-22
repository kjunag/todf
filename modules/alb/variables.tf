variable "project_name" {
  type        = string
  description = "Project name"
}

variable "public_subnets" {
  type        = list(any)
  description = "List of public subnets"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for security groups"
}

variable "certificate_arn" {
  type        = string
  description = "ARN of ACM certificate for HTTPS listener"
}
