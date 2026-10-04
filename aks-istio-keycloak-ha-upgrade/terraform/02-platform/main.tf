locals {
  # Folder that holds helm/ and k8s/ (two levels above this layer). The same
  # values files and manifests are used by the shell scripts, so both ways of
  # installing stay in sync.
  repo_root = abspath("${path.module}/../..")

  # Revision name of the active Istio version: 1.28.1 -> 1-28-1
  active_revision = replace(var.istio_active_version, ".", "-")

  # The newest installed Istio version, compared number by number
  # (1.9 < 1.28). The CRDs (base chart) always follow the newest version.
  istio_sortable       = { for v in var.istio_revisions : format("%05d%05d%05d", split(".", v)...) => v }
  newest_istio_version = local.istio_sortable[reverse(sort(keys(local.istio_sortable)))[0]]

  # StorageClass for shared (ReadWriteMany) volumes.
  shared_storage_class = var.storage_backend == "azurefiles-nfs" ? "azurefile-csi-nfs" : "nfs"

  # k8s/namespaces.yaml with the placeholder replaced. The shell scripts put
  # the revision TAG ("stable") into the istio.io/rev label; here the label
  # holds the revision itself, because the variable istio_active_version
  # already is the single switch.
  namespaces = {
    for object in provider::kubernetes::manifest_decode_multi(
      replace(file("${local.repo_root}/k8s/namespaces.yaml"), "__ISTIO_TAG__", local.active_revision)
    ) : object.metadata.name => object
  }
}

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "namespace" {
  for_each = local.namespaces
  manifest = each.value
}

# ---------------------------------------------------------------------------
# Shared storage
# ---------------------------------------------------------------------------

# StorageClass of the Azure disk behind the NFS pod.
resource "kubernetes_manifest" "nfs_backing_disk_class" {
  count = var.storage_backend == "nfs-pod" ? 1 : 0
  manifest = provider::kubernetes::manifest_decode(
    replace(file("${local.repo_root}/k8s/storage/nfs-backing-disk-storageclass.yaml"), "__NFS_BACKING_DISK_SKU__", var.nfs_backing_disk_sku)
  )
}

# The NFS server pod and its StorageClass "nfs".
resource "helm_release" "nfs" {
  count = var.storage_backend == "nfs-pod" ? 1 : 0

  name       = "nfs-server-provisioner"
  repository = var.nfs_helm_repo
  chart      = "nfs-server-provisioner"
  version    = var.nfs_chart_version
  namespace  = "nfs-storage"
  values     = [file("${local.repo_root}/helm/values/nfs-server-provisioner.yaml")]
  set = [
    { name = "persistence.size", value = var.nfs_disk_size }
  ]
  # Undo a failed install or upgrade automatically.
  atomic  = true
  timeout = var.helm_timeout_seconds

  depends_on = [kubernetes_manifest.namespace, kubernetes_manifest.nfs_backing_disk_class]
}

# Alternative: Azure Files NFS shares - Azure runs the NFS service.
resource "kubernetes_manifest" "azurefile_nfs_class" {
  count    = var.storage_backend == "azurefiles-nfs" ? 1 : 0
  manifest = provider::kubernetes::manifest_decode(file("${local.repo_root}/k8s/storage/azurefile-nfs-storageclass.yaml"))
}

# ---------------------------------------------------------------------------
# Istio
# ---------------------------------------------------------------------------

# CRDs and the default validation webhook. Always at the newest installed
# version (CRDs are backward compatible and are never downgraded).
resource "helm_release" "istio_base" {
  name       = "istio-base"
  repository = var.istio_helm_repo
  chart      = "base"
  version    = local.newest_istio_version
  namespace  = "istio-system"
  set = [
    # The istiod that validates Istio objects - always the active one.
    { name = "defaultRevision", value = local.active_revision }
  ]
  atomic  = true
  timeout = var.helm_timeout_seconds

  depends_on = [kubernetes_manifest.namespace]

  lifecycle {
    precondition {
      condition     = contains(var.istio_revisions, var.istio_active_version)
      error_message = "istio_active_version must be one of istio_revisions (install a control plane before you activate it, and never remove the active one)."
    }
  }
}

# One control plane per entry of istio_revisions, each as its own release
# (istiod-1-28-1, istiod-1-29-8, ...), so two versions can run side by side.
resource "helm_release" "istiod" {
  for_each = var.istio_revisions

  name       = "istiod-${replace(each.value, ".", "-")}"
  repository = var.istio_helm_repo
  chart      = "istiod"
  version    = each.value
  namespace  = "istio-system"
  values     = [file("${local.repo_root}/helm/values/istiod.yaml")]
  set = [
    { name = "revision", value = replace(each.value, ".", "-") }
  ]
  atomic  = true
  timeout = var.helm_timeout_seconds

  depends_on = [helm_release.istio_base]
}

# ---------------------------------------------------------------------------
# TLS: a private certificate authority and a wildcard certificate.
# For production use a real certificate (for example cert-manager).
# ---------------------------------------------------------------------------

resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem
  subject {
    organization = "AKS HA Upgrade Example"
    common_name  = "AKS HA Upgrade Example Local CA (Terraform)"
  }
  # Two years.
  validity_period_hours = 17520
  is_ca_certificate     = true
  allowed_uses          = ["cert_signing", "crl_signing"]
}

resource "tls_private_key" "server" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server" {
  private_key_pem = tls_private_key.server.private_key_pem
  subject {
    common_name = "*.${local.infra.base_domain}"
  }
  # Valid for app1, app2 and keycloak.
  dns_names = ["*.${local.infra.base_domain}"]
}

resource "tls_locally_signed_cert" "server" {
  cert_request_pem   = tls_cert_request.server.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem
  # 90 days. An apply during the last 30 days issues a new certificate; the
  # gateway picks it up without a restart.
  validity_period_hours = 2160
  early_renewal_hours   = 720
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

# The certificate as a secret next to the ingress gateway.
resource "kubernetes_secret_v1" "wildcard_tls" {
  metadata {
    name      = "wildcard-tls"
    namespace = "istio-ingress"
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = tls_locally_signed_cert.server.cert_pem
    "tls.key" = tls_private_key.server.private_key_pem
  }

  depends_on = [kubernetes_manifest.namespace]
}

# ---------------------------------------------------------------------------
# Gateways. "revision" labels the pods with istio.io/rev=<active revision>;
# changing the active version changes the label, which makes Kubernetes
# replace the pods one by one (new pod first, PodDisruptionBudget respected).
# ---------------------------------------------------------------------------

resource "helm_release" "ingress_gateway" {
  name       = "istio-ingressgateway"
  repository = var.istio_helm_repo
  chart      = "gateway"
  version    = var.istio_active_version
  namespace  = "istio-ingress"
  values = [
    file("${local.repo_root}/helm/values/istio-ingressgateway.yaml"),
    # Use the static public IP from layer 1 for the Azure load balancer.
    yamlencode({
      service = {
        annotations = {
          "service.beta.kubernetes.io/azure-load-balancer-resource-group" = local.infra.resource_group_name
          "service.beta.kubernetes.io/azure-pip-name"                     = local.infra.public_ip_name
        }
      }
    })
  ]
  set = [
    { name = "revision", value = local.active_revision }
  ]
  atomic  = true
  timeout = var.helm_timeout_seconds

  depends_on = [helm_release.istiod, kubernetes_secret_v1.wildcard_tls]
}

resource "helm_release" "egress_gateway" {
  name       = "istio-egressgateway"
  repository = var.istio_helm_repo
  chart      = "gateway"
  version    = var.istio_active_version
  namespace  = "istio-egress"
  values     = [file("${local.repo_root}/helm/values/istio-egressgateway.yaml")]
  set = [
    { name = "revision", value = local.active_revision }
  ]
  atomic  = true
  timeout = var.helm_timeout_seconds

  depends_on = [helm_release.istiod]
}
