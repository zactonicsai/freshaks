# Cluster driver: Amazon EKS.
# Builds a small VPC, the cluster, one managed node group and the add-ons.
# Credentials come from the environment (AWS_PROFILE, AWS_* keys or a role on the Jenkins agent).

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.59"
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
  cidr    = try(local.cluster.network.cidr, "10.0.0.0/16")
  azs     = slice(data.aws_availability_zones.available.names, 0, min(3, length(data.aws_availability_zones.available.names)))

  # Hosted add-ons: every enabled add-on that the catalog maps to an EKS add-on name.
  # gitops/platform applies the same rule and skips the Helm chart for these.
  catalog = try(local.cfg.hostedAddonCatalog.eks, {})
  hosted = {
    for key, addon in try(local.cfg.addons, {}) : key => local.catalog[key]
    if try(addon.enabled, true) && try(addon.hosted, true) && try(local.cluster.hostedAddons, true)
    && try(local.catalog[key], "builtin") != "builtin"
  }
}

provider "aws" {
  region = local.cluster.region

  default_tags {
    tags = {
      platform   = local.cfg.platform.name
      cluster    = local.name
      managed-by = "terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = local.cidr
  azs  = local.azs

  private_subnets = [for i, az in local.azs : cidrsubnet(local.cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(local.cidr, 8, 48 + i)]

  enable_nat_gateway = true
  single_nat_gateway = true

  # Lets Kubernetes place load balancers in the right subnets.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# Role for the EBS CSI driver, assumed through EKS Pod Identity.
resource "aws_iam_role" "ebs_csi" {
  name = "${local.name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = local.cluster.kubernetesVersion

  # Jenkins reaches the API over the public endpoint. Set publicEndpoint: false
  # under cluster.network when the agents run inside the VPC.
  endpoint_public_access = try(local.cluster.network.publicEndpoint, true)

  # The identity that runs Terraform becomes cluster-admin, so the bootstrap can follow.
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = merge(
    {
      vpc-cni                = { before_compute = true }
      eks-pod-identity-agent = { before_compute = true }
      kube-proxy             = {}
      coredns                = {}
      aws-ebs-csi-driver = {
        pod_identity_association = [{
          role_arn        = aws_iam_role.ebs_csi.arn
          service_account = "ebs-csi-controller-sa"
        }]
      }
    },
    { for key, addon_name in local.hosted : addon_name => {} },
  )

  eks_managed_node_groups = {
    default = {
      instance_types = [local.cluster.nodes.size]
      min_size       = try(local.cluster.nodes.min, local.cluster.nodes.count)
      max_size       = try(local.cluster.nodes.max, local.cluster.nodes.count)
      desired_size   = local.cluster.nodes.count
    }
  }
}

output "cluster_name" {
  value = module.eks.cluster_name
}
