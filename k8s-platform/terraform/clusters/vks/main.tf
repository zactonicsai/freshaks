# Cluster driver: VMware vSphere Kubernetes Service (VKS).
# A VKS cluster is a Cluster API object in a vSphere Namespace on the Supervisor.
# Terraform applies that object with the Kubernetes provider and waits until it is available.
# Log in to the Supervisor first; cluster.supervisor points at that kubeconfig and context.

terraform {
  required_version = ">= 1.6"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
}

variable "config_file" {
  description = "Merged configuration, written by scripts/lib/common.sh."
  type        = string
}

locals {
  cfg        = yamldecode(file(var.config_file))
  cluster    = local.cfg.cluster
  name       = local.cluster.name
  supervisor = local.cluster.supervisor
}

provider "kubernetes" {
  config_path    = pathexpand(local.supervisor.kubeconfig)
  config_context = try(local.supervisor.context, null)
}

resource "kubernetes_manifest" "cluster" {
  manifest = {
    apiVersion = "cluster.x-k8s.io/v1beta2"
    kind       = "Cluster"
    metadata = {
      name      = local.name
      namespace = local.supervisor.namespace
      labels = {
        platform = local.cfg.platform.name
      }
    }
    spec = {
      clusterNetwork = {
        pods     = { cidrBlocks = [try(local.cluster.network.pods, "192.168.0.0/16")] }
        services = { cidrBlocks = [try(local.cluster.network.services, "10.96.0.0/12")] }
      }
      topology = {
        classRef = {
          name      = local.cluster.clusterClass
          namespace = "vmware-system-vks-public"
        }
        version = local.cluster.kubernetesVersion # a Kubernetes release name from "kubectl get kr"
        controlPlane = {
          replicas = try(local.cluster.nodes.controlPlane, 3)
        }
        workers = {
          machineDeployments = [{
            class    = "node-pool"
            name     = "workers"
            replicas = local.cluster.nodes.count
          }]
        }
        variables = [
          { name = "vmClass", value = local.cluster.nodes.size },
          { name = "storageClass", value = local.cluster.storageClass },
        ]
      }
    }
  }

  # Cluster API v1beta2 reports readiness as "Available". On a v1beta1 Supervisor use "Ready".
  wait {
    condition {
      type   = "Available"
      status = "True"
    }
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "30m"
  }
}

output "cluster_name" {
  value = local.name
}
