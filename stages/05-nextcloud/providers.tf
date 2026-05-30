terraform {
  required_version = ">= 1.5"

  backend "s3" {
    key = "stages/05-nextcloud/terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
