# Values that the next two layers (and the helper scripts) read from this
# layer's state file.

output "resource_group_name" {
  description = "Resource group that holds everything."
  value       = azurerm_resource_group.this.name
}

output "aks_name" {
  description = "Name of the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.name
}

output "current_kubernetes_version" {
  description = "Exact version (with patch number) the control plane runs."
  value       = azurerm_kubernetes_cluster.this.current_kubernetes_version
}

output "acr_name" {
  description = "Name of the container registry."
  value       = azurerm_container_registry.this.name
}

output "acr_login_server" {
  description = "Host name of the registry, used in image names."
  value       = azurerm_container_registry.this.login_server
}

output "public_ip_name" {
  description = "Name of the static public IP (for the load balancer annotation)."
  value       = azurerm_public_ip.ingress.name
}

output "public_ip_address" {
  description = "Address of the ingress gateway."
  value       = azurerm_public_ip.ingress.ip_address
}

output "base_domain" {
  description = "nip.io turns any IP into DNS names: app1.<ip>.nip.io resolves to <ip>."
  value       = "${azurerm_public_ip.ingress.ip_address}.nip.io"
}

output "kube_config" {
  description = "Admin credentials of the cluster for the kubernetes and helm providers of layers 2 and 3."
  sensitive   = true
  value = {
    host                   = azurerm_kubernetes_cluster.this.kube_config[0].host
    client_certificate     = azurerm_kubernetes_cluster.this.kube_config[0].client_certificate
    client_key             = azurerm_kubernetes_cluster.this.kube_config[0].client_key
    cluster_ca_certificate = azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
  }
}

output "kube_config_raw" {
  description = "Complete kubeconfig file, for kubectl."
  sensitive   = true
  value       = azurerm_kubernetes_cluster.this.kube_config_raw
}
