# Layer 2 of 3: what the cluster needs before workloads can run - namespaces,
# shared NFS storage, Istio (control planes and gateways) and the TLS
# certificate. It reads the cluster credentials from the state of layer 1.
#
# Why separate layers? The kubernetes and helm providers need the address and
# credentials of the cluster, and those exist only after layer 1 was applied.

terraform {
  required_version = ">= 1.8.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    # Creates the private CA and the wildcard certificate.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
  }
}

# Read the outputs of layer 1 from its local state file.
data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "${path.module}/../01-infra/terraform.tfstate"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs
  kube  = local.infra.kube_config
}

# Talks to the Kubernetes API (namespaces, secrets, plain manifests).
provider "kubernetes" {
  host                   = local.kube.host
  client_certificate     = base64decode(local.kube.client_certificate)
  client_key             = base64decode(local.kube.client_key)
  cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
}

# Installs Helm charts into the same cluster.
provider "helm" {
  kubernetes = {
    host                   = local.kube.host
    client_certificate     = base64decode(local.kube.client_certificate)
    client_key             = base64decode(local.kube.client_key)
    cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
  }
}
