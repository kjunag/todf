variable "project_name" {
  type        = string
  description = "Project name"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "private_subnets" {
  type        = list(any)
  description = "Private subnets for ECS tasks and ElastiCache"
}

variable "efs_id" {
  type        = string
  description = "EFS file system ID"
}

variable "ecs_cluster_id" {
  type        = string
  description = "ECS cluster ID"
}

variable "ecs_execution_role_arn" {
  type        = string
  description = "ECS task execution role ARN"
}

variable "db_endpoint" {
  type        = string
  description = "Aurora PostgreSQL writer endpoint"
}

variable "db_secret_arn" {
  type        = string
  description = "Secrets Manager ARN for DB credentials (JSON with username/password)"
}

variable "secret_key_arn" {
  type        = string
  description = "Secrets Manager ARN for Authentik secret key (plain string)"
}

variable "authentik_bootstrap_password_arn" {
  type        = string
  description = "Secrets Manager ARN for akadmin bootstrap password"
}

variable "alb_sg_id" {
  type        = string
  description = "ALB security group ID"
}

variable "https_listener_arn" {
  type        = string
  description = "HTTPS ALB listener ARN for adding routing rules"
}

variable "root_domain" {
  type        = string
  description = "Root domain (e.g. todf.mom)"
}

variable "authentik_version" {
  type        = string
  description = "Authentik container image version tag"
  default     = "2024.12.3"
}
