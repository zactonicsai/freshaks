# -----------------------------------------------------------------------------
# variables.tf — values are written to terraform.tfvars by lib/common.sh
#                (tf_write_tfvars) from config.env. Edit config.env, not the
#                tfvars file.
# -----------------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription that contains the cluster."
  type        = string
}

variable "resource_group" {
  description = "Resource group that contains the AKS cluster (informational; IDs in the generated config are absolute)."
  type        = string
}

variable "cluster_name" {
  description = "AKS managed cluster name (informational)."
  type        = string
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig written by `az aks get-credentials`; used by the kubernetes and helm providers."
  type        = string
}
