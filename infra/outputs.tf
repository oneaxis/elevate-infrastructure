output "gateway_url" {
  description = "Public HTTPS endpoint of the AI gateway (send the App Check token via the X-Firebase-AppCheck header)."
  value       = google_cloudfunctions2_function.gateway.service_config[0].uri
}

output "workload_identity_provider" {
  description = "Fully qualified WIF provider path. Set as the WIF_PROVIDER GitHub Actions variable."
  value       = "https://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.github.workload_identity_pool_provider_id}"
}

output "deployer_service_account" {
  description = "Deployer service account email. Set as the DEPLOY_SA GitHub Actions variable."
  value       = google_service_account.deployer.email
}

output "runtime_service_account" {
  description = "Runtime service account email (the only identity with secretAccessor on the API keys)."
  value       = google_service_account.runtime.email
}

output "artifact_registry_url" {
  description = "Docker repository for gateway images (auto-pruned to the 2 most recent versions)."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/ai-gateway"
}
