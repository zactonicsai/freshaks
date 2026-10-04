# ---------------------------------------------------------------------------
# PostgreSQL - upgrade switches
# ---------------------------------------------------------------------------
# A major upgrade (14 -> 18) cannot reuse the data folder. The steps:
#   1. add the new instance:    postgres_instances = { postgres-v14 = {...}, postgres-v18 = { version = "18.6" } }
#   2. stop Keycloak:           keycloak_replicas = 0
#   3. copy the data:           terraform/scripts/postgres-migrate.sh postgres-v14 postgres-v18
#   4. switch and start:        postgres_active_release = "postgres-v18", keycloak_replicas = 2
#   5. later, park the old one: postgres-v14 = { version = "14.12", replicas = 0 }   (or remove the line)
# To roll back after step 4: stop Keycloak, set postgres_active_release back, start Keycloak.

variable "postgres_instances" {
  description = "PostgreSQL releases to run, keyed by Helm release name (postgres-v<major>). replicas = 0 parks an instance but keeps its volume."
  type = map(object({
    version  = string
    replicas = optional(number, 1)
  }))
  default = {
    postgres-v14 = { version = "14.12" }
  }
}

variable "postgres_active_release" {
  description = "The instance that the stable Service 'postgres' points at. Must be a key of postgres_instances."
  type        = string
  default     = "postgres-v14"
}

variable "postgres_image_repository" {
  description = "Where the PostgreSQL image comes from."
  type        = string
  default     = "docker.io/library/postgres"
}

variable "postgres_data_size" {
  description = "Size of each PostgreSQL data volume. It cannot be changed after the first install."
  type        = string
  default     = "8Gi"
}

# ---------------------------------------------------------------------------
# Keycloak - upgrade switches
# ---------------------------------------------------------------------------
# An upgrade across major versions (24 -> 26) changes the database tables:
#   1. back up the database:    terraform/scripts/postgres-backup.sh
#   2. apply with               keycloak_version = "26.8.0", keycloak_update_strategy = "Recreate"
#   3. apply again with         keycloak_update_strategy = "RollingUpdate"

variable "keycloak_version" {
  description = "Keycloak image tag. Versions 25 and newer automatically get the values file with the new option names."
  type        = string
  default     = "24.0.5"
}

variable "keycloak_replicas" {
  description = "Number of Keycloak pods. Set to 0 to stop Keycloak during a database migration."
  type        = number
  default     = 2
}

variable "keycloak_update_strategy" {
  description = "RollingUpdate for everyday changes; Recreate for a version upgrade (old and new pods must never run together)."
  type        = string
  default     = "RollingUpdate"

  validation {
    condition     = contains(["RollingUpdate", "Recreate"], var.keycloak_update_strategy)
    error_message = "Use RollingUpdate or Recreate."
  }
}

variable "keycloak_image_repository" {
  description = "Where the Keycloak image comes from."
  type        = string
  default     = "quay.io/keycloak/keycloak"
}

# ---------------------------------------------------------------------------
# Applications - upgrade switch
# ---------------------------------------------------------------------------

variable "app_version" {
  description = "Image tag of both applications. Build and push it first with terraform/scripts/build-images.sh <tag>. Changing it is a rolling update."
  type        = string
  default     = "1.0.0"
}

# ---------------------------------------------------------------------------
# Egress and storage sizes
# ---------------------------------------------------------------------------

variable "egress_allowed_host" {
  description = "The one external host that pods may call (through the egress gateway)."
  type        = string
  default     = "api.ipify.org"
}

variable "egress_blocked_host" {
  description = "A host that is NOT allowed; the apps use it to show that the mesh blocks it."
  type        = string
  default     = "example.com"
}

variable "backup_volume_size" {
  description = "Size of the shared volume for database dumps."
  type        = string
  default     = "10Gi"
}

variable "shared_notes_size" {
  description = "Size of the shared volume for the notes of the two applications."
  type        = string
  default     = "1Gi"
}

variable "helm_timeout_seconds" {
  description = "How long Helm waits for pods to become ready before it rolls a release back."
  type        = number
  default     = 900
}
