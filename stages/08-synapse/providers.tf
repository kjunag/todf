terraform {
  required_version = ">= 1.5"

  backend "s3" {
    key = "stages/08-synapse/terraform.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.2.0" # Używamy tej samej wersji co w Vaultwarden
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- POBRANIE DANYCH AUTHENTIKA ---
data "terraform_remote_state" "authentik" {
  backend = "s3"
  config = {
    bucket         = var.tf_state_bucket
    key            = "stages/04-authentik/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = var.tf_state_lock_table
    encrypt        = true
  }
}

data "aws_secretsmanager_secret" "authentik_token" {
  name = "${var.project_name}/authentik_api_token"
}

data "aws_secretsmanager_secret_version" "authentik_token" {
  secret_id = data.aws_secretsmanager_secret.authentik_token.id
}

provider "authentik" {
  url   = data.terraform_remote_state.authentik.outputs.authentik_url
  token = jsondecode(data.aws_secretsmanager_secret_version.authentik_token.secret_string)["password"]
}
