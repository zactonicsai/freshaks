locals {
  # Nodes follow the control plane unless a separate version is given.
  node_pool_version = coalesce(var.node_pool_kubernetes_version, var.kubernetes_version)
}

# Everything lives in one resource group; deleting it deletes the example.
resource "azurerm_resource_group" "this" {
  name     = "rg-${var.prefix}"
  location = var.location
  tags     = var.tags
}

# Registry names are global in Azure, so a random suffix is added.
resource "random_string" "acr_suffix" {
  length  = 8
  upper   = false
  special = false
}

# Container registry for the images of the two applications.
resource "azurerm_container_registry" "this" {
  name                = "acr${var.prefix}${random_string.acr_suffix.result}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = var.acr_sku
  # No admin password: the cluster pulls with its managed identity.
  admin_enabled = false
  tags          = var.tags
}

# Static, zone-redundant public IP for the Istio ingress gateway. Because it
# is our own resource it survives every upgrade and even a new cluster.
resource "azurerm_public_ip" "ingress" {
  name                = "pip-${var.prefix}-ingress"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zones
  tags                = var.tags
}

# The AKS cluster with its system node pool.
resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  dns_prefix          = var.prefix

  # Control plane version. Changing it upgrades ONLY the control plane.
  kubernetes_version = var.kubernetes_version
  # Uptime SLA for the control plane.
  sku_tier = var.aks_sku_tier

  # No automatic upgrades: in this example every upgrade is a deliberate
  # change of a variable. (automatic_upgrade_channel is left unset = none.)
  # In production consider a channel together with a maintenance window.
  node_os_upgrade_channel = "None"

  default_node_pool {
    name       = "system"
    vm_size    = var.system_node_size
    node_count = var.system_node_count
    # One node per availability zone.
    zones = var.zones
    # Taint the pool so that only cluster add-ons run here.
    only_critical_addons_enabled = true
    # Node version; changing it rolls the nodes one by one.
    orchestrator_version = local.node_pool_version
    # Needed by the provider when a change forces new nodes (e.g. VM size):
    # it creates a temporary pool with this name while it rebuilds "system".
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge                     = var.max_surge
      drain_timeout_in_minutes      = var.drain_timeout_minutes
      node_soak_duration_in_minutes = var.node_soak_minutes
    }
  }

  # Managed identity instead of a service principal: no secret to rotate.
  identity {
    type = "SystemAssigned"
  }

  # Azure CNI Overlay: pods get private addresses from pod_cidr, so the
  # virtual network does not run out of IPs during surge upgrades.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = var.pod_cidr
    load_balancer_sku   = "standard"
  }

  # Node auto-provisioning (Karpenter) is not used; node pools are explicit.
  node_provisioning_profile {
    mode = "Manual"
  }

  tags = var.tags
}

# The node pools for the workloads (Istio, NFS, PostgreSQL, Keycloak, apps).
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  for_each = var.user_node_pools

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"
  vm_size               = each.value.vm_size
  node_count            = each.value.node_count
  zones                 = var.zones
  # Per-pool version (blue/green) or the common node version.
  orchestrator_version = coalesce(each.value.kubernetes_version, local.node_pool_version)

  upgrade_settings {
    max_surge                     = var.max_surge
    drain_timeout_in_minutes      = var.drain_timeout_minutes
    node_soak_duration_in_minutes = var.node_soak_minutes
  }

  tags = var.tags
}

# Let the cluster attach our static public IP to its load balancer. The IP is
# in OUR resource group (not in the node resource group that AKS manages), so
# the cluster identity needs the Network Contributor role there.
resource "azurerm_role_assignment" "cluster_network" {
  scope                            = azurerm_resource_group.this.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_kubernetes_cluster.this.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Let the nodes pull images from the registry (same as "az aks create --attach-acr").
resource "azurerm_role_assignment" "nodes_acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
