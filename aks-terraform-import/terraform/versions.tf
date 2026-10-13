# -----------------------------------------------------------------------------
# versions.tf — Terraform core and provider version pins
# -----------------------------------------------------------------------------
# Terraform >= 1.5 is required because the import scripts rely on two features
# introduced there:
#   * `import {}` blocks           — declarative imports, applied with `terraform apply`
#   * `plan -generate-config-out`  — Terraform writes resource {} blocks for you
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Azure Resource Manager: resource group, networking, AKS, disks, storage,
    # ACR, Key Vault, Log Analytics, identities, role assignments ...
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    # Objects INSIDE the cluster: namespaces, deployments, services, ingresses,
    # config maps, PVCs ... (import ID = "namespace/name")
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }

    # Helm releases (import ID = "namespace/release"). The 2.x series is
    # pinned because 3.x changed the provider block syntax
    # (`kubernetes {}` block became a `kubernetes = {}` attribute).
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
