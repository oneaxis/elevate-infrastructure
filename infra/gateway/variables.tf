variable "project_id" {
  description = "GCP project id that hosts the gateway function."
  type        = string
}

variable "region" {
  description = "Deployment region."
  type        = string
}

variable "function_name" {
  description = "Cloud Function name (e.g. ai-gateway for production, ai-gateway-dev for development)."
  type        = string
}

variable "source_bucket_name" {
  description = "Name of the bucket holding the packaged function source (shared across environments)."
  type        = string
}

variable "runtime_service_account_email" {
  description = "Execution identity of the function (needs secretAccessor on all provider secrets)."
  type        = string
}

variable "function_source_path" {
  description = "Path to the packaged function zip, relative to this module."
  type        = string
  default     = "../../build/function.zip"
}

variable "chain_main" {
  description = "Ordered main-tier failover chain, 'provider:model' entries."
  type        = string
}

variable "chain_secondary" {
  description = "Ordered secondary-tier failover chain, 'provider:model' entries."
  type        = string
}

variable "provider_base_urls" {
  description = "OpenAI-compatible base URL per provider, keyed by provider name."
  type        = map(string)
}

variable "provider_secrets" {
  description = "Secret Manager secret id per provider, keyed by provider name. The runtime reads them as {PROVIDER}_API_KEY."
  type        = map(string)
}

variable "upstream_timeout_ms" {
  description = "Per-attempt upstream timeout."
  type        = number
  default     = 8000
}

variable "total_budget_ms" {
  description = "Total latency budget for one request across the whole chain."
  type        = number
  default     = 25000
}
