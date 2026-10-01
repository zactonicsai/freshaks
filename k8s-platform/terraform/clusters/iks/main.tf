# Cluster driver: IBM Cloud Kubernetes Service on VPC.
# Credentials come from the environment (IC_API_KEY).

terraform {
  required_version = ">= 1.6"
  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = "~> 2.6"
    }
  }
}

variable "config_file" {
  description = "Merged configuration, written by scripts/lib/common.sh."
  type        = string
}

locals {
  cfg     = yamldecode(file(var.config_file))
  cluster = local.cfg.cluster
  name    = local.cluster.name
  tags    = ["platform:${local.cfg.platform.name}", "cluster:${local.name}", "managed-by:terraform"]

  # Hosted add-ons: every enabled add-on that the catalog maps to an IBM Cloud add-on name.
  # gitops/platform applies the same rule and skips the Helm chart for these.
  catalog = try(local.cfg.hostedAddonCatalog.iks, {})
  hosted = {
    for key, addon in try(local.cfg.addons, {}) : key => local.catalog[key]
    if try(addon.enabled, true) && try(addon.hosted, true) && try(local.cluster.hostedAddons, true)
    && try(local.catalog[key], "builtin") != "builtin"
  }
}

provider "ibm" {
  region = local.cluster.region
}

data "ibm_resource_group" "this" {
  name = local.cluster.resourceGroup
}

resource "ibm_is_vpc" "this" {
  name           = local.name
  resource_group = data.ibm_resource_group.this.id
  tags           = local.tags
}

# Outbound internet access for the workers (image pulls).
resource "ibm_is_public_gateway" "this" {
  name           = "${local.name}-gateway"
  vpc            = ibm_is_vpc.this.id
  zone           = local.cluster.zone
  resource_group = data.ibm_resource_group.this.id
  tags           = local.tags
}

resource "ibm_is_subnet" "this" {
  name                     = "${local.name}-${local.cluster.zone}"
  vpc                      = ibm_is_vpc.this.id
  zone                     = local.cluster.zone
  total_ipv4_address_count = 256
  public_gateway           = ibm_is_public_gateway.this.id
  resource_group           = data.ibm_resource_group.this.id
  tags                     = local.tags
}

resource "ibm_container_vpc_cluster" "this" {
  name              = local.name
  vpc_id            = ibm_is_vpc.this.id
  kube_version      = local.cluster.kubernetesVersion
  flavor            = local.cluster.nodes.size
  worker_count      = local.cluster.nodes.count
  resource_group_id = data.ibm_resource_group.this.id
  wait_till         = "IngressReady"
  tags              = local.tags

  zones {
    name      = local.cluster.zone
    subnet_id = ibm_is_subnet.this.id
  }

  timeouts {
    create = "90m"
    delete = "60m"
  }
}

resource "ibm_container_addons" "hosted" {
  count = length(local.hosted) > 0 ? 1 : 0

  cluster           = ibm_container_vpc_cluster.this.id
  resource_group_id = data.ibm_resource_group.this.id

  dynamic "addons" {
    for_each = local.hosted
    content {
      name = addons.value
    }
  }
}

output "cluster_name" {
  value = ibm_container_vpc_cluster.this.name
}
