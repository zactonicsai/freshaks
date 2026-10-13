# -----------------------------------------------------------------------------
# backend.tf — where the state file lives
# -----------------------------------------------------------------------------
# Default: a LOCAL state file (terraform/terraform.tfstate). Fine for a one-off
# migration; NOT fine for a team or for a state that now contains Kubernetes
# secrets / Key Vault secrets. To move to Azure Storage:
#
#   1. Create the storage account + container, e.g.
#        az group create -n rg-tfstate -l eastus
#        az storage account create -n sttfstate123 -g rg-tfstate --sku Standard_LRS
#        az storage container create -n tfstate --account-name sttfstate123
#   2. Uncomment the block below and fill in the names.
#   3. Run `terraform init -migrate-state` from this directory.
#
# terraform {
#   backend "azurerm" {
#     resource_group_name  = "rg-tfstate"
#     storage_account_name = "sttfstate123"
#     container_name       = "tfstate"
#     key                  = "aks-prod.tfstate"
#     use_azuread_auth     = true   # authenticate with the `az login` identity
#   }
# }
