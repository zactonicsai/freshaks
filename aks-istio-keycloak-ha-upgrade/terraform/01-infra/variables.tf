# ---------------------------------------------------------------------------
# Naming and location
# ---------------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription id. Null = take it from the environment variable ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "prefix" {
  description = "Short name that becomes part of every resource name. Different from the shell example (hademo) so both can exist side by side."
  type        = string
  default     = "hademotf"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.prefix))
    error_message = "Use 3 to 12 lowercase letters and digits, starting with a letter."
  }
}

variable "location" {
  description = "Azure region. It must offer three availability zones."
  type        = string
  default     = "eastus2"
}

variable "zones" {
  description = "Availability zones for the nodes and the public IP."
  type        = list(string)
  default     = ["1", "2", "3"]
}

# ---------------------------------------------------------------------------
# Kubernetes versions - THE UPGRADE SWITCHES of this layer
# ---------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "Version of the control plane, as minor version (AKS then picks the newest patch). Raise it by ONE minor version at a time: 1.34 -> 1.35 -> 1.36. It can never be lowered."
  type        = string
  default     = "1.34"
}

variable "node_pool_kubernetes_version" {
  description = "Version of the nodes. Null = same as the control plane. To upgrade in two steps, first raise kubernetes_version (control plane only), apply, then raise this one (nodes roll one by one), apply."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Cluster size
# ---------------------------------------------------------------------------

variable "aks_sku_tier" {
  description = "Standard = control plane with a financially backed uptime SLA. Free has none."
  type        = string
  default     = "Standard"
}

variable "system_node_size" {
  description = "VM size of the system nodes (they run only cluster add-ons)."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "system_node_count" {
  description = "Number of system nodes. Three = one per availability zone."
  type        = number
  default     = 3
}

variable "user_node_pools" {
  description = <<-EOT
    The node pools that run the workloads. One pool is enough for normal use.
    For a blue/green node upgrade add a second pool with the new version,
    apply, wait until the pods have moved, then remove the old pool and apply
    again (AKS drains a pool before it deletes it).
    kubernetes_version = null means "same as node_pool_kubernetes_version".
  EOT
  type = map(object({
    vm_size            = optional(string, "Standard_D4s_v5")
    node_count         = optional(number, 3)
    kubernetes_version = optional(string)
  }))
  default = {
    apps = {}
  }
}

# ---------------------------------------------------------------------------
# Upgrade behaviour of the node pools
# ---------------------------------------------------------------------------

variable "max_surge" {
  description = "Extra nodes added during a node pool upgrade so capacity never drops. 33% of three nodes = one extra node."
  type        = string
  default     = "33%"
}

variable "drain_timeout_minutes" {
  description = "How long AKS waits for the pods of one node to leave (PodDisruptionBudgets can delay this)."
  type        = number
  default     = 30
}

variable "node_soak_minutes" {
  description = "Pause after each upgraded node before the next one is touched."
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Network and registry
# ---------------------------------------------------------------------------

variable "pod_cidr" {
  description = "Private address range for pods (Azure CNI Overlay)."
  type        = string
  default     = "10.244.0.0/16"
}

variable "acr_sku" {
  description = "Registry tier. Premium adds zone redundancy and geo-replication (use it in production)."
  type        = string
  default     = "Standard"
}

variable "tags" {
  description = "Tags put on every Azure resource."
  type        = map(string)
  default = {
    purpose = "aks-ha-upgrade-example"
    managed = "terraform"
  }
}
