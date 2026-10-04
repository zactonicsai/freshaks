# Values that layer 3 and the helper scripts read from this layer's state.

output "istio_active_version" {
  description = "The Istio version that injects sidecars."
  value       = var.istio_active_version
}

output "istio_active_revision" {
  description = "Revision name of the active Istio version (dots replaced by dashes)."
  value       = local.active_revision
}

output "shared_storage_class" {
  description = "StorageClass for shared (ReadWriteMany) volumes."
  value       = local.shared_storage_class
}

output "ca_certificate_pem" {
  description = "Certificate of the private CA. Import it into your browser, or save it: tofu output -raw ca_certificate_pem > ca.crt"
  value       = tls_self_signed_cert.ca.cert_pem
}
