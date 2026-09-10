#!/usr/bin/env bash
#
# One-time bootstrap for the AI gateway OpenTofu backend.
#
# The remote state bucket cannot be managed by OpenTofu itself (it holds the
# state), so it is created here exactly once. Everything else is provisioned
# declaratively from /infra.
#
# The bucket lives in the US multi-region on purpose: GCP's Always Free tier
# includes 5 GB-month of Standard storage plus 5k Class-A / 50k Class-B
# operations per month for US buckets, which keeps the OpenTofu state at $0.
#
# Usage:
#   ./scripts/bootstrap.sh <PROJECT_ID>
#
# Requirements: gcloud CLI authenticated as a project owner.
set -euo pipefail

PROJECT_ID="${1:?Usage: ./scripts/bootstrap.sh <PROJECT_ID>}"
STATE_BUCKET="${STATE_BUCKET:-elevate-ai-gateway-tofu-state}"

gcloud config set project "$PROJECT_ID"

echo "==> Ensuring required APIs are enabled (free)"
gcloud services enable \
  cloudfunctions.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  storage.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  firebaseappcheck.googleapis.com

echo "==> Creating OpenTofu state bucket gs://${STATE_BUCKET} (US multi-region)"
if gcloud storage buckets describe "gs://${STATE_BUCKET}" --format="value(name)" >/dev/null 2>&1; then
  echo "    Bucket already exists, skipping creation."
else
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --location=US \
    --uniform-bucket-level-access \
    --public-access-prevention
fi

echo "==> Enabling object versioning on the state bucket (state history)"
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning

echo
echo "Bootstrap done. Next steps:"
echo "  1. cd infra && tofu init"
echo "  2. cp terraform.tfvars.example terraform.tfvars  # set project_id"
echo "  3. tofu plan && tofu apply   # run locally once with owner credentials"
echo "     (this creates Workload Identity Federation + the deployer SA)"
echo "  4. tofu output workload_identity_provider  -> gh variable set WIF_PROVIDER"
echo "     tofu output deployer_service_account    -> gh variable set DEPLOY_SA"
echo "  5. Push to main; GitHub Actions takes over via WIF (no stored keys)."
