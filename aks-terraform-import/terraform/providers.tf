# -----------------------------------------------------------------------------
# providers.tf — how Terraform authenticates to Azure and to the cluster
# -----------------------------------------------------------------------------

# Azure: uses the same `az login` session as the shell scripts (Azure CLI
# authentication is the provider's default when no client secret / MSI
# settings are present).
provider "azurerm" {
  subscription_id = var.subscription_id

  # Do not try to register resource providers at plan time. Registration needs
  # subscription-level rights that a resource-group Contributor may not have,
  # and everything we import is already registered anyway.
  resource_provider_registrations = "none"

  features {
    # `terraform destroy` on an imported resource group would otherwise refuse
    # to run while anything the state does not know about is still inside it.
    resource_group {
      prevent_deletion_if_contains_resources = false
    }

    # Key Vault is soft-deleted by default; purging it on destroy makes the
    # name reusable immediately. Set to false to keep the 90-day recovery window.
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }

    # Log Analytics workspaces are also soft-deleted (14 days) unless forced.
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
  }
}

# Kubernetes objects: read from the kubeconfig that
# `az aks get-credentials` wrote (see KUBECONFIG_PATH in config.env).
# A file is used instead of the azurerm_kubernetes_cluster resource so that the
# provider still works while the cluster itself is being imported or destroyed.
provider "kubernetes" {
  config_path = var.kubeconfig_path
}

# Helm releases: same kubeconfig.
provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}
