# Stack 2: GitOps bootstrap. Identical for every cluster type.
# Installs Argo CD and one root Application that points back at this repository.
# From then on Argo CD installs everything else (gitops/platform renders the list).

terraform {
  required_version = ">= 1.6"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
  }
}

variable "config_file" {
  description = "Merged configuration, written by scripts/lib/common.sh."
  type        = string
}

variable "kubeconfig" {
  description = "Kubeconfig written by the cluster driver's kubeconfig.sh."
  type        = string
}

variable "git_username" {
  description = "User for a private Git repository (TF_VAR_git_username)."
  type        = string
  default     = "git"
}

variable "git_token" {
  description = "Read-only token for a private Git repository (TF_VAR_git_token). Empty for a public repository."
  type        = string
  default     = ""
  sensitive   = true
}

locals {
  cfg     = yamldecode(file(var.config_file))
  gitops  = local.cfg.gitops
  cluster = local.cfg.cluster.name
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = local.gitops.argocd.chartVersion
  values           = [yamlencode(try(local.gitops.argocd.values, {}))]
  timeout          = 900

  # Private repository: the token is stored as an Argo CD credential template,
  # never in Git. Rotate it by changing the Jenkins credential and redeploying.
  set_sensitive = var.git_token == "" ? [] : [
    { name = "configs.credentialTemplates.platform.url", value = local.gitops.repoURL },
    { name = "configs.credentialTemplates.platform.username", value = var.git_username },
    { name = "configs.credentialTemplates.platform.password", value = var.git_token },
  ]
}

# The root Application (app of apps). It renders gitops/platform with the same
# two config files every other tool reads.
resource "helm_release" "root" {
  name       = "root"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = local.gitops.argocd.appsChartVersion
  depends_on = [helm_release.argocd]

  values = [yamlencode({
    applications = {
      root = {
        namespace  = "argocd"
        project    = "default"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = local.gitops.repoURL
          targetRevision = local.gitops.revision
          path           = "gitops/platform"
          helm = {
            valueFiles = [
              "/config/global.yaml",
              "/config/clusters/${local.cluster}.yaml",
            ]
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
        }
      }
    }
  })]
}
