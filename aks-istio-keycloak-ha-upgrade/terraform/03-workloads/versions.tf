# Layer 3 of 3: the workloads - PostgreSQL, Keycloak, the two applications -
# plus the Istio policies and routes around them. It reads the cluster
# credentials from layer 1 and the Istio/storage facts from layer 2.
#
# Why a third layer? The Istio objects (Gateway, VirtualService, ...) are
# custom resources. Terraform can only plan them when their definitions (CRDs)
# already exist in the cluster, and those are installed by layer 2.

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
    # Generates the passwords.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

# Outputs of layer 1 (cluster credentials, registry, host names).
data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = "${path.module}/../01-infra/terraform.tfstate"
  }
}

# Outputs of layer 2 (active Istio revision, storage class).
data "terraform_remote_state" "platform" {
  backend = "local"
  config = {
    path = "${path.module}/../02-platform/terraform.tfstate"
  }
}

locals {
  infra    = data.terraform_remote_state.infra.outputs
  platform = data.terraform_remote_state.platform.outputs
  kube     = local.infra.kube_config
}

provider "kubernetes" {
  host                   = local.kube.host
  client_certificate     = base64decode(local.kube.client_certificate)
  client_key             = base64decode(local.kube.client_key)
  cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = local.kube.host
    client_certificate     = base64decode(local.kube.client_certificate)
    client_key             = base64decode(local.kube.client_key)
    cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
  }
}
