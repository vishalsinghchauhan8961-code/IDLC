terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial backend config. Real values are supplied by the pipeline:
  #   terraform init -backend-config=envs/<env>.backend.hcl
  # Nothing secret lives here; auth to the state account uses the pipeline's
  # workload identity (OIDC), not a storage key.
  backend "azurerm" {}
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    key_vault {
      # Never hard-purge state we may need to recover during an incident.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "random" {}
