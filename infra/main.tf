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
# Secret Manager (provider API keys, shared by all gateway environments)
###############################################################################

resource "google_secret_manager_secret" "provider_key" {
  for_each = toset(keys(var.provider_base_urls))

  secret_id = "${upper(each.key)}_API_KEY"
  replication {
    auto {}
  }
}

# Placeholder versions so the very first deployment succeeds; rotate with
# `gcloud secrets versions add GLM_API_KEY --data-file=-` (Secret Manager's
# 6 active versions are free).
resource "google_secret_manager_secret_version" "provider_key" {
  for_each = google_secret_manager_secret.provider_key

  secret      = each.value.name
  secret_data = var.provider_initial_keys[each.key]
  lifecycle {
    ignore_changes = [secret_data]
  }
}

###############################################################################
# Function source bucket (US = Always Free storage tier, shared by prod + dev)
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

###############################################################################
# Gateway environments: production + development
#
# Both run the identical function against the shared secrets; dev exists so
# app development never burns production capacity or noise on prod logs.
###############################################################################

module "prod" {
  source = "./gateway"

  project_id                    = var.project_id
  region                        = var.region
  function_name                 = "ai-gateway"
  source_bucket_name            = google_storage_bucket.function_source.name
  runtime_service_account_email = google_service_account.runtime.email
  chain_main                    = var.chain_main
  chain_secondary               = var.chain_secondary
  provider_base_urls            = var.provider_base_urls
  provider_secrets              = { for name, secret in google_secret_manager_secret.provider_key : name => secret.secret_id }
}

module "dev" {
  source = "./gateway"

  project_id                    = var.project_id
  region                        = var.region
  function_name                 = "ai-gateway-dev"
  source_bucket_name            = google_storage_bucket.function_source.name
  runtime_service_account_email = google_service_account.runtime.email
  chain_main                    = var.chain_main
  chain_secondary               = var.chain_secondary
  provider_base_urls            = var.provider_base_urls
  provider_secrets              = { for name, secret in google_secret_manager_secret.provider_key : name => secret.secret_id }
}

# State migration: these resources used to live in the root module. Moving
# (instead of recreate) keeps the production function — and above all the
# rotated secret versions — untouched.
moved {
  from = google_secret_manager_secret.glm_api_key
  to   = google_secret_manager_secret.provider_key["glm"]
}

moved {
  from = google_secret_manager_secret.groq_api_key
  to   = google_secret_manager_secret.provider_key["groq"]
}

moved {
  from = google_secret_manager_secret_version.glm_api_key
  to   = google_secret_manager_secret_version.provider_key["glm"]
}

moved {
  from = google_secret_manager_secret_version.groq_api_key
  to   = google_secret_manager_secret_version.provider_key["groq"]
}

moved {
  from = google_storage_bucket_object.function_source
  to   = module.prod.google_storage_bucket_object.function_source
}

moved {
  from = google_cloudfunctions2_function.gateway
  to   = module.prod.google_cloudfunctions2_function.gateway
}

moved {
  from = google_cloudfunctions2_function_iam_member.public_invoker
  to   = module.prod.google_cloudfunctions2_function_iam_member.public_invoker
}
