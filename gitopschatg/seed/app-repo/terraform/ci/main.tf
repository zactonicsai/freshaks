terraform {
  required_version = ">= 1.6.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30, < 3.0"
    }
  }
}

provider "kubernetes" {
  host                   = "https://kubernetes.default.svc"
  token                  = file("/var/run/secrets/kubernetes.io/serviceaccount/token")
  cluster_ca_certificate = file("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
}

# Read-only on purpose. This proves Terraform can talk to Kubernetes,
# without giving Jenkins a second application deployment path.
data "kubernetes_namespace_v1" "default" {
  metadata {
    name = "default"
  }
}

output "checked_namespace" {
  value = data.kubernetes_namespace_v1.default.metadata[0].name
}
