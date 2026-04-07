terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# S3 
resource "aws_s3_bucket" "terraform_state" {
  bucket = "${var.project_name}-tfstate-bucket" # Nazwa musi być unikalna globalnie!
}

# Versioning
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Server side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}


# DynamoDB block 
resource "aws_dynamodb_table" "terraform_state_lock" {
  name         = "${var.project_name}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST" 
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# Create file with backend config
resource "local_file" "backend_config" {
  filename = "../backend_config.hcl"
  content  = <<-EOT
    bucket         = "${aws_s3_bucket.terraform_state.bucket}"
    key            = "base/terraform.tfstate"
    region         = "${var.aws_region}"
    dynamodb_table = "${aws_dynamodb_table.terraform_state_lock.name}"
    encrypt        = true
  EOT
}