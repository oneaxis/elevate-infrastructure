terraform {
  backend "gcs" {
    # Created once by scripts/bootstrap.sh (US multi-region stays inside the
    # Always Free tier: 5 GB-month standard storage + Class A/B operations).
    # If the name is taken, change it here AND in bootstrap.sh.
    bucket = "elevate-ai-gateway-tofu-state"
    prefix = "ai-gateway"
  }
}
