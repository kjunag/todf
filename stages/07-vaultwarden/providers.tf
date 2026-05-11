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
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "authentik" {
  url   = data.terraform_remote_state.authentik.outputs.authentik_url
  token = jsondecode(data.aws_secretsmanager_secret_version.authentik_token.secret_string)["password"]
}
