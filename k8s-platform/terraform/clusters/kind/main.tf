# Cluster driver: kind (Kubernetes in Docker or Podman).
# kind has no official Terraform provider, so Terraform wraps the kind CLI.
# Local clusters therefore follow the same plan / apply / destroy path as cloud ones.

terraform {
  required_version = ">= 1.6"
}

variable "config_file" {
  description = "Merged configuration, written by scripts/lib/common.sh."
  type        = string
}

locals {
  cfg     = yamldecode(file(var.config_file))
  cluster = local.cfg.cluster
  runtime = try(local.cluster.runtime, "docker")
  image   = try(local.cluster.nodeImage, "kindest/node:v${local.cluster.kubernetesVersion}")
  workers = try(local.cluster.nodes.count, 0)

  kind_config = yamlencode({
    kind       = "Cluster"
    apiVersion = "kind.x-k8s.io/v1alpha4"
    nodes = concat(
      [{ role = "control-plane", image = local.image }],
      [for i in range(local.workers) : { role = "worker", image = local.image }],
    )
  })
}

resource "terraform_data" "cluster" {
  # A new node image, node count or runtime replaces the cluster.
  triggers_replace = [local.kind_config, local.cluster.name, local.runtime]

  # A destroy provisioner may only read "self", so its inputs are stored here.
  input = {
    name    = local.cluster.name
    runtime = local.runtime
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "kind get clusters | grep -qx \"$NAME\" || kind create cluster --name \"$NAME\" --wait 180s --config - <<<\"$KIND_CONFIG\""
    environment = {
      NAME                       = local.cluster.name
      KIND_CONFIG                = local.kind_config
      KIND_EXPERIMENTAL_PROVIDER = local.runtime
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "kind delete cluster --name \"$NAME\""
    environment = {
      NAME                       = self.input.name
      KIND_EXPERIMENTAL_PROVIDER = self.input.runtime
    }
  }
}

output "cluster_name" {
  value = local.cluster.name
}
