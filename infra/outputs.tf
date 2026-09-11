output "gateway_url" {
  description = "Public HTTPS endpoint of the production AI gateway (send the App Check token via the X-Firebase-AppCheck header)."
  value       = module.prod.gateway_url
}

output "gateway_url_dev" {
  description = "Public HTTPS endpoint of the development gateway. App dev builds pass it via --dart-define=ELVT_AI_GATEWAY_URL=<url>."
  value       = module.dev.gateway_url
}

output "workload_identity_provider" {
  description = "WIF provider entity name. Set as the WIF_PROVIDER GitHub Actions variable (google-github-actions/auth expects the //iam.googleapis.com/... resource-name form)."
  value       = "//iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.github.workload_identity_pool_provider_id}"
}

output "deployer_service_account" {
  description = "Deployer service account email. Set as the DEPLOY_SA GitHub Actions variable."
  value       = google_service_account.deployer.email
}

output "runtime_service_account" {
  description = "Runtime service account email (the only identity with secretAccessor on the provider API keys)."
  value       = google_service_account.runtime.email
}

output "artifact_registry_url" {
  description = "Docker repository for gateway images (auto-pruned to the 2 most recent versions)."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/ai-gateway"
}
