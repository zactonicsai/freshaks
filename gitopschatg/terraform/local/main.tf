terraform {
  required_version = ">= 1.6.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30, < 3.0"
    }
  }
}

variable "kubeconfig" {
  type    = string
  default = "~/.kube/config"
}

variable "context" {
  type    = string
  default = "kind-gitops-lab"
}

provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig)
  config_context = var.context
}

# There are intentionally NO Kubernetes resources in this Terraform root.
# It is a safe teaching example of provider connectivity and state refresh.
data "kubernetes_namespace_v1" "default" {
  metadata {
    name = "default"
  }
}

output "connected_namespace" {
  value = data.kubernetes_namespace_v1.default.metadata[0].name
}
