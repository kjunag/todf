terraform {
  required_version = ">= 1.5"

  backend "s3" {
    key = "stages/01-dns/terraform.tfstate"
  }

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
