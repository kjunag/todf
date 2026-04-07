variable "project_name" {
  type = string
  description = "Project name"
}

variable "public_subnets" {
  type = list(any)
  description = "List of public subnets"
}