# Cluster driver: Azure Kubernetes Service.
# Credentials come from the environment (ARM_* variables, a managed identity or "az login").

terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.7"
    }
  }
}

variable "config_file" {
  description = "Merged configuration, written by scripts/lib/common.sh."
  type        = string
}

locals {
  cfg     = yamldecode(file(var.config_file))
  cluster = local.cfg.cluster
  name    = local.cluster.name
  nodes   = local.cluster.nodes.count
  max     = try(local.cluster.nodes.max, local.nodes)
  tags = {
    platform   = local.cfg.platform.name
    cluster    = local.name
    managed-by = "terraform"
  }

  # Hosted add-ons: every enabled add-on that the catalog maps to an AKS extension type.
  # gitops/platform applies the same rule and skips the Helm chart for these.
  catalog = try(local.cfg.hostedAddonCatalog.aks, {})
  hosted = {
    for key, addon in try(local.cfg.addons, {}) : key => local.catalog[key]
    if try(addon.enabled, true) && try(addon.hosted, true) && try(local.cluster.hostedAddons, true)
    && try(local.catalog[key], "builtin") != "builtin"
  }
}

provider "azurerm" {
  subscription_id = try(local.cluster.subscriptionId, null) # or ARM_SUBSCRIPTION_ID

  features {}
}

resource "azurerm_resource_group" "this" {
  name     = try(local.cluster.resourceGroup, "rg-${local.name}")
  location = local.cluster.region
  tags     = local.tags
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = local.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = local.name
  kubernetes_version  = local.cluster.kubernetesVersion
  tags                = local.tags

  # Ready for workload identity, so pods need no stored cloud credentials.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                 = "default"
    vm_size              = local.cluster.nodes.size
    auto_scaling_enabled = local.max > local.nodes
    node_count           = local.nodes
    min_count            = local.max > local.nodes ? try(local.cluster.nodes.min, local.nodes) : null
    max_count            = local.max > local.nodes ? local.max : null

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
  }

  # azurerm 5 requires this block. "Manual" keeps node pools under Terraform.
  node_provisioning_profile {
    mode = "Manual"
  }

  lifecycle {
    # The autoscaler owns the node count after creation.
    ignore_changes = [default_node_pool[0].node_count]
  }
}

resource "azurerm_kubernetes_cluster_extension" "hosted" {
  for_each = local.hosted

  name           = each.key
  cluster_id     = azurerm_kubernetes_cluster.this.id
  extension_type = each.value
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}
