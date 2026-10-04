locals {
  # Folder that holds helm/ and k8s/ (two levels above this layer).
  repo_root = abspath("${path.module}/../..")

  base_domain = local.infra.base_domain

  # Keycloak 25 renamed many options; pick the matching values file.
  keycloak_values_file = tonumber(split(".", var.keycloak_version)[0]) >= 25 ? "keycloak-current-v26.yaml" : "keycloak-legacy-v24.yaml"

  # The manifests under k8s/ contain __PLACEHOLDERS__ (the shell scripts fill
  # them with sed). The same files are used here, so both ways of installing
  # stay in sync. HCL has no "replace many" function, so the calls are nested.
  manifest_files = [
    "k8s/storage/pvc-pg-backups.yaml",
    "k8s/storage/pvc-shared-notes.yaml",
    "k8s/postgres/serviceaccount.yaml",
    "k8s/postgres/service-active.yaml",
    "k8s/istio/peer-authentication.yaml",
    "k8s/istio/authorization-policies.yaml",
    "k8s/istio/egress.yaml",
    "k8s/istio/gateway.yaml",
    "k8s/istio/virtualservices.yaml",
    "k8s/istio/destinationrules.yaml",
  ]
  rendered = {
    for path in local.manifest_files : path => replace(replace(replace(replace(replace(replace(
      file("${local.repo_root}/${path}"),
      "__BASE_DOMAIN__", local.base_domain),
      "__EGRESS_HOST__", var.egress_allowed_host),
      "__POSTGRES_ACTIVE_RELEASE__", var.postgres_active_release),
      "__SHARED_STORAGE_CLASS__", local.platform.shared_storage_class),
      "__BACKUP_VOLUME_SIZE__", var.backup_volume_size),
    "__SHARED_NOTES_SIZE__", var.shared_notes_size)
  }
  # One entry per Kubernetes object, keyed "Kind/namespace/name".
  objects = merge([
    for path, text in local.rendered : {
      for object in provider::kubernetes::manifest_decode_multi(text) :
      "${object.kind}/${try(object.metadata.namespace, "-")}/${object.metadata.name}" => object
    }
  ]...)

  # Split by purpose, because they are created at different moments.
  volume_claims   = { for key, object in local.objects : key => object if object.kind == "PersistentVolumeClaim" }
  postgres_basics = { for key, object in local.objects : key => object if contains(["ServiceAccount", "Service"], object.kind) }
  istio_objects   = { for key, object in local.objects : key => object if endswith(object.apiVersion, "istio.io/v1") }

  # Pods get this annotation. When the active Istio revision changes (layer 2),
  # the annotation changes, and Kubernetes replaces the pods one by one - that
  # is how the workloads pick up the new sidecar.
  mesh_annotation = { "demo.example.com/mesh-revision" = local.platform.istio_active_revision }
}

# ---------------------------------------------------------------------------
# Passwords: generated once, stored in the state (keep the state private!)
# and handed to the cluster as Kubernetes secrets.
# ---------------------------------------------------------------------------

resource "random_password" "postgres" {
  length  = 24
  special = false
}

resource "random_password" "keycloak_db" {
  length  = 24
  special = false
}

resource "random_password" "keycloak_admin" {
  length  = 24
  special = false
}

resource "random_password" "client_secret" {
  for_each = toset(["app1", "app2"])
  length   = 32
  special  = false
}

resource "random_password" "test_user" {
  length  = 20
  special = false
}

resource "kubernetes_secret_v1" "postgres_credentials" {
  metadata {
    name      = "postgres-credentials"
    namespace = "postgres"
  }
  data = {
    "postgres-password"    = random_password.postgres.result
    "keycloak-db-password" = random_password.keycloak_db.result
  }
}

resource "kubernetes_secret_v1" "keycloak_credentials" {
  metadata {
    name      = "keycloak-credentials"
    namespace = "keycloak"
  }
  data = {
    "admin-username" = "admin"
    "admin-password" = random_password.keycloak_admin.result
    "db-password"    = random_password.keycloak_db.result
  }
}

resource "kubernetes_secret_v1" "app_oidc" {
  for_each = random_password.client_secret
  metadata {
    name      = "${each.key}-oidc"
    namespace = "apps"
  }
  data = {
    "client-secret" = each.value.result
  }
}

# ---------------------------------------------------------------------------
# Shared volumes (ReadWriteMany on NFS)
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "volume_claim" {
  for_each = local.volume_claims
  manifest = each.value

  # Do not continue before the storage really exists.
  wait {
    fields = {
      "status.phase" = "Bound"
    }
  }
}

# ---------------------------------------------------------------------------
# Mesh policies, egress and routes (the same YAML files as the shell path)
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "istio" {
  for_each = local.istio_objects
  manifest = each.value
}

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------

# ServiceAccount shared by all instances, and the stable Service "postgres"
# whose selector names the active instance.
resource "kubernetes_manifest" "postgres_basics" {
  for_each = local.postgres_basics
  manifest = each.value
}

resource "helm_release" "postgres" {
  for_each = var.postgres_instances

  name      = each.key
  chart     = "${local.repo_root}/helm/charts/postgres"
  namespace = "postgres"
  values = [
    yamlencode({
      image = {
        repository = var.postgres_image_repository
        tag        = each.value.version
      }
      replicaCount = each.value.replicas
      persistence = {
        storageClass = local.platform.shared_storage_class
        size         = var.postgres_data_size
      }
      podAnnotations = local.mesh_annotation
    })
  ]
  atomic  = true
  timeout = var.helm_timeout_seconds

  depends_on = [
    kubernetes_secret_v1.postgres_credentials,
    kubernetes_manifest.volume_claim,
    kubernetes_manifest.postgres_basics,
    kubernetes_manifest.istio,
  ]

  lifecycle {
    precondition {
      condition     = each.key == "postgres-v${split(".", each.value.version)[0]}"
      error_message = "Name every instance postgres-v<major version>, for example postgres-v18 for version 18.6."
    }
    precondition {
      condition     = contains(keys(var.postgres_instances), var.postgres_active_release)
      error_message = "postgres_active_release must be a key of postgres_instances."
    }
  }
}

# ---------------------------------------------------------------------------
# Keycloak
# ---------------------------------------------------------------------------

resource "helm_release" "keycloak" {
  name      = "keycloak"
  chart     = "${local.repo_root}/helm/charts/keycloak"
  namespace = "keycloak"
  values = [
    file("${local.repo_root}/helm/values/${local.keycloak_values_file}"),
    # Marked sensitive because it contains the client secrets and the test password.
    sensitive(yamlencode({
      image = {
        repository = var.keycloak_image_repository
        tag        = var.keycloak_version
      }
      replicaCount   = var.keycloak_replicas
      updateStrategy = var.keycloak_update_strategy
      baseDomain     = local.base_domain
      podAnnotations = local.mesh_annotation
      realm = {
        clients = {
          app1 = { secret = random_password.client_secret["app1"].result }
          app2 = { secret = random_password.client_secret["app2"].result }
        }
        testUserPassword = "Demo-${random_password.test_user.result}"
      }
    }))
  ]
  atomic  = true
  timeout = var.helm_timeout_seconds

  depends_on = [
    kubernetes_secret_v1.keycloak_credentials,
    helm_release.postgres,
    kubernetes_manifest.postgres_basics,
  ]
}

# ---------------------------------------------------------------------------
# The two Spring Boot applications
# ---------------------------------------------------------------------------

resource "helm_release" "app" {
  for_each = toset(["app1", "app2"])

  name      = each.key
  chart     = "${local.repo_root}/helm/charts/spring-app"
  namespace = "apps"
  values = [
    file("${local.repo_root}/helm/values/${each.key}.yaml"),
    yamlencode({
      image = {
        repository = "${local.infra.acr_login_server}/${each.key}"
        tag        = var.app_version
      }
      baseDomain   = local.base_domain
      meshRevision = local.platform.istio_active_revision
      egress = {
        allowedHost = var.egress_allowed_host
        blockedHost = var.egress_blocked_host
      }
    })
  ]
  atomic  = true
  timeout = var.helm_timeout_seconds

  depends_on = [
    kubernetes_secret_v1.app_oidc,
    kubernetes_manifest.volume_claim,
    helm_release.keycloak,
  ]
}
