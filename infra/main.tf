###############################################################################
# Artifact Registry with strict cleanup policies (< 0.5 GB free tier cap)
###############################################################################

resource "google_artifact_registry_repository" "gateway" {
  project       = var.project_id
  location      = var.region
  repository_id = "ai-gateway"
  description   = "AI gateway container images (auto-pruned)"
  format        = "DOCKER"

  # Keep only the 2 most recent versions.
  cleanup_policies {
    id     = "keep-last-2"
    action = "KEEP"
    most_recent_versions {
      keep_count = 2
    }
  }

  # Drop untagged layers after a day.
  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "1d"
    }
  }

  # Drop anything older than a week (KEEP policies take precedence).
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "7d"
    }
  }
}

###############################################################################
# Secret Manager (provider API keys, injected as function env vars)
###############################################################################

resource "google_secret_manager_secret" "glm_api_key" {
  secret_id = "GLM_API_KEY"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "groq_api_key" {
  secret_id = "GROQ_API_KEY"
  replication {
    auto {}
  }
}

# Placeholder versions so the very first deployment succeeds; rotate with
# `gcloud secrets versions add GLM_API_KEY --data-file=-` (Secret Manager's
# 6 active versions are free).
resource "google_secret_manager_secret_version" "glm_api_key" {
  secret      = google_secret_manager_secret.glm_api_key.name
  secret_data = var.glm_api_key
  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret_version" "groq_api_key" {
  secret      = google_secret_manager_secret.groq_api_key.name
  secret_data = var.groq_api_key
  lifecycle {
    ignore_changes = [secret_data]
  }
}

###############################################################################
# Function source bucket + packaged source (US = Always Free storage tier)
###############################################################################

resource "google_storage_bucket" "function_source" {
  name                        = "${var.project_id}-ai-gateway-source"
  location                    = "US"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    condition {
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_storage_bucket_object" "function_source" {
  name         = "function-source-${substr(filesha1("${path.module}/${var.function_source_path}"), 0, 12)}.zip"
  bucket       = google_storage_bucket.function_source.name
  source       = "${path.module}/${var.function_source_path}"
  content_type = "application/zip"
}

###############################################################################
# Cloud Functions 2nd gen (Cloud Run) gateway
###############################################################################

resource "google_cloudfunctions2_function" "gateway" {
  name     = "ai-gateway"
  project  = var.project_id
  location = var.region

  build_config {
    runtime     = "nodejs22"
    entry_point = "aiGateway"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
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
    service_account_email = google_service_account.runtime.email

    environment_variables = {
      GLM_BASE_URL         = var.glm_base_url
      GROQ_BASE_URL        = var.groq_base_url
      GLM_MODEL            = var.glm_model
      GROQ_FAILOVER_MODELS = join(",", var.groq_failover_models)
      GROQ_SECONDARY_MODEL = var.groq_secondary_model
    }

    secret_environment_variables {
      key        = "GLM_API_KEY"
      project_id = var.project_id
      secret     = google_secret_manager_secret.glm_api_key.secret_id
      version    = "latest"
    }

    secret_environment_variables {
      key        = "GROQ_API_KEY"
      project_id = var.project_id
      secret     = google_secret_manager_secret.groq_api_key.secret_id
      version    = "latest"
    }
  }
}
