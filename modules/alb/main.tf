resource "aws_lb" "main" {
  name               = var.project_name
  internal           = false
  load_balancer_type = "application"
 # security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnets
  enable_deletion_protection = false

  tags = { Name = var.project_name }
}