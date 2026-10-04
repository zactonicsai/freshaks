# Layer 1 of 3: the Azure resources (resource group, registry, public IP, AKS).
# Works with Terraform 1.8+ and OpenTofu 1.7+ (the later layers use
# provider-defined functions, which need these versions).

terraform {
  required_version = ">= 1.8.0"

  required_providers {
    # Azure Resource Manager provider. Pinned to the 5.x line that this
    # example was validated against.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.8"
    }
    # Used for the random part of the registry name.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # The state is kept in a local file (terraform.tfstate in this folder) to
  # keep the example simple. It contains the cluster's admin credentials:
  # keep it private. For a team use a remote backend, for example:
  #
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "mytfstate"
  #   container_name       = "tfstate"
  #   key                  = "aks-ha-example/01-infra.tfstate"
  # }
}

provider "azurerm" {
  # The (empty) features block is mandatory.
  features {}
  # Which subscription to use. When left null the provider reads the
  # environment variable ARM_SUBSCRIPTION_ID.
  subscription_id = var.subscription_id
}
