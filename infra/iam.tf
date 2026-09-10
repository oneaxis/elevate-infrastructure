data "google_project" "this" {
  project_id = var.project_id
}

###############################################################################
# Service accounts
###############################################################################

# Used by GitHub Actions (via WIF) and by humans running tofu locally as owner.
resource "google_service_account" "deployer" {
  account_id   = "ai-gateway-deployer"
  display_name = "AI Gateway deployer (OpenTofu / GitHub Actions)"
}

# Execution identity of the Cloud Function. It is the ONLY identity allowed to
# read the provider API key secrets.
resource "google_service_account" "runtime" {
  account_id   = "ai-gateway-runtime"
  display_name = "AI Gateway function runtime"
}

resource "google_service_account_iam_member" "deployer_actas_runtime" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

###############################################################################
# Workload Identity Federation (keyless CI auth, no service account keys)
###############################################################################

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions pool"
  description               = "Federated identity for ${var.github_repository}"
  disabled                  = false
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions-provider"
  display_name                       = "GitHub Actions OIDC provider"
  attribute_condition                = "assertion.repository == \"${var.github_repository}\""
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Trust only tokens issued for this repository (plan + apply workflows).
resource "google_service_account_iam_member" "deployer_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

###############################################################################
# Deployer permissions
#
# The issue's minimal role list (developer/writer/viewer) only covers
# *updates* of existing resources. The first `tofu apply` has to create the
# registry, secrets, buckets and the function, so the deployer needs the
# admin variants below. All of them are free.
###############################################################################

resource "google_project_iam_member" "deployer_roles" {
  for_each = toset([
    "roles/cloudfunctions.admin",
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
    "roles/storage.admin",
    # IAM plane: manage service accounts + their IAM bindings, the WIF
    # pool/provider, and the project-level bindings declared in this module.
    "roles/iam.serviceAccountAdmin",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/resourcemanager.projectIamAdmin",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
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

###############################################################################
# Function runtime permissions
###############################################################################

resource "google_project_iam_member" "runtime_roles" {
  for_each = toset([
    "roles/artifactregistry.reader",
    "roles/monitoring.metricWriter",
    "roles/logging.logWriter",
    # Verifies (and consumes) the App Check tokens sent by clients.
    "roles/firebaseappcheck.tokenVerifier",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# Direct secret access is granted ONLY to the function's runtime service
# account (never to the deployer, never to humans).
resource "google_secret_manager_secret_iam_member" "runtime_glm_accessor" {
  secret_id = google_secret_manager_secret.glm_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "runtime_groq_accessor" {
  secret_id = google_secret_manager_secret.groq_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}
