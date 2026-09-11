###############################################################################
# Packaged function source (shared US bucket, per-environment object)
###############################################################################

resource "google_storage_bucket_object" "function_source" {
  name         = "${var.function_name}-${substr(filesha1("${path.module}/${var.function_source_path}"), 0, 12)}.zip"
  bucket       = var.source_bucket_name
  source       = "${path.module}/${var.function_source_path}"
  content_type = "application/zip"
}

###############################################################################
# Cloud Functions 2nd gen (Cloud Run) gateway
###############################################################################

resource "google_cloudfunctions2_function" "gateway" {
  name     = var.function_name
  project  = var.project_id
  location = var.region

  build_config {
    runtime     = "nodejs22"
    entry_point = "aiGateway"
    source {
      storage_source {
        bucket = var.source_bucket_name
        object = google_storage_bucket_object.function_source.name
      }
    }
  }

  service_config {
    min_instance_count    = 0 # scale to zero
    max_instance_count    = 10
    available_memory      = "256M"
    timeout_seconds       = 30
    ingress_settings      = "ALLOW_ALL"
    service_account_email = var.runtime_service_account_email

    # The function reads a generic ordered failover chain; all supported
    # providers are OpenAI-compatible, so adding one means adding a
    # {PROVIDER}_BASE_URL + {PROVIDER}_API_KEY secret, never code changes.
    environment_variables = merge(
      {
        AI_CHAIN_MAIN       = var.chain_main
        AI_CHAIN_SECONDARY  = var.chain_secondary
        UPSTREAM_TIMEOUT_MS = tostring(var.upstream_timeout_ms)
        TOTAL_BUDGET_MS     = tostring(var.total_budget_ms)
      },
      { for provider, url in var.provider_base_urls : "${upper(provider)}_BASE_URL" => url }
    )

    # Provider API keys mount from Secret Manager. Rotating a key = new
    # secret version, no redeploy.
    dynamic "secret_environment_variables" {
      for_each = var.provider_secrets
      content {
        key        = "${upper(secret_environment_variables.key)}_API_KEY"
        project_id = var.project_id
        secret     = secret_environment_variables.value
        version    = "latest"
      }
    }
  }
}

###############################################################################
# Public, authless invocation
#
# The gateway is intentionally reachable without GCP credentials ("authless"):
# every request must instead carry a valid, consumed Firebase App Check token,
# enforced by the function itself. No other ingress protection is applied.
###############################################################################

resource "google_cloudfunctions2_function_iam_member" "public_invoker" {
  project        = var.project_id
  location       = var.region
  cloud_function = google_cloudfunctions2_function.gateway.name
  role           = "roles/cloudfunctions.invoker"
  member         = "allUsers"
  depends_on     = [google_cloudfunctions2_function.gateway]
}

resource "google_cloud_run_service_iam_member" "public_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.gateway.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

