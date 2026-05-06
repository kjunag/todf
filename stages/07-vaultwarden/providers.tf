terraform {
  required_version = ">= 1.5"

  backend "s3" {
    key = "stages/07-vaultwarden/terraform.tfstate"
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
