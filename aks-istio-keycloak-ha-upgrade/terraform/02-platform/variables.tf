# ---------------------------------------------------------------------------
# Istio - THE UPGRADE SWITCHES of this layer
# ---------------------------------------------------------------------------
# A canary upgrade from 1.28.1 to 1.29.8 is four small applies:
#   1. istio_revisions = ["1.28.1", "1.29.8"]      new control plane installed,
#                                                   nothing uses it yet
#   2. istio_active_version = "1.29.8"             namespaces and gateways switch;
#                                                   then apply layer 3 so the
#                                                   workloads restart with the
#                                                   new sidecar
#   3. (check everything)
#   4. istio_revisions = ["1.29.8"]                old control plane removed
# To roll back before step 4: set istio_active_version back and apply both layers.

variable "istio_revisions" {
  description = "Istio versions whose control plane (istiod) is installed. Two entries during an upgrade, one otherwise."
  type        = set(string)
  default     = ["1.28.1"]
}

variable "istio_active_version" {
  description = "The Istio version that injects sidecars and runs the gateways. Must be one of istio_revisions. Move ONE minor version at a time."
  type        = string
  default     = "1.28.1"
}

variable "istio_helm_repo" {
  description = "Helm repository of the Istio charts."
  type        = string
  default     = "https://blob.istio.io/istio-release/charts"
}

# ---------------------------------------------------------------------------
# Shared storage
# ---------------------------------------------------------------------------

variable "storage_backend" {
  description = "nfs-pod = NFS server pod on an Azure disk (default). azurefiles-nfs = Azure Files NFS shares (no pod to look after, the choice for production)."
  type        = string
  default     = "nfs-pod"

  validation {
    condition     = contains(["nfs-pod", "azurefiles-nfs"], var.storage_backend)
    error_message = "Use nfs-pod or azurefiles-nfs."
  }
}

variable "nfs_backing_disk_sku" {
  description = "Disk type behind the NFS pod. Premium_ZRS is copied to three zones, so the pod can restart in any zone."
  type        = string
  default     = "Premium_ZRS"
}

variable "nfs_disk_size" {
  description = "Size of the disk behind the NFS pod."
  type        = string
  default     = "64Gi"
}

variable "nfs_chart_version" {
  description = "Version of the nfs-server-provisioner chart."
  type        = string
  default     = "1.8.0"
}

variable "nfs_helm_repo" {
  description = "Helm repository of the NFS server chart."
  type        = string
  default     = "https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/"
}

variable "helm_timeout_seconds" {
  description = "How long Helm waits for pods to become ready before it rolls a release back."
  type        = number
  default     = 900
}
