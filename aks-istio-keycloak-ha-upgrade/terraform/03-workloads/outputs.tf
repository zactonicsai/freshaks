output "urls" {
  description = "Addresses of the two applications and the Keycloak admin console."
  value = {
    portal   = "https://app1.${local.base_domain}"
    reports  = "https://app2.${local.base_domain}"
    keycloak = "https://keycloak.${local.base_domain}/admin/"
  }
}

output "test_users" {
  description = "Users of realm 'demo'. alice also has the role admin."
  value       = ["alice", "bob", "carol"]
}

output "test_user_password" {
  description = "Password of alice, bob and carol. Show it with: tofu output -raw test_user_password"
  sensitive   = true
  value       = "Demo-${random_password.test_user.result}"
}

output "keycloak_admin_password" {
  description = "Password of the Keycloak user 'admin'. Show it with: tofu output -raw keycloak_admin_password"
  sensitive   = true
  value       = random_password.keycloak_admin.result
}

output "postgres_active_release" {
  description = "The PostgreSQL instance behind the Service 'postgres'."
  value       = var.postgres_active_release
}
