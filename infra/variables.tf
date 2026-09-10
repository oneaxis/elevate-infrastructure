variable "project_id" {
  description = "GCP project id that hosts the AI gateway."
  type        = string
}

variable "region" {
  description = "Deployment region. Defaults to us-central1 so Cloud Functions 2nd gen usage stays inside the Always Free tier."
  type        = string
  default     = "us-central1"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) allowed to authenticate via Workload Identity Federation."
  type        = string
  default     = "oneaxis/elevate-infrastructure"
}

variable "function_source_path" {
  description = "Path to the packaged Cloud Function zip (built via `npm run package` in /functions)."
  type        = string
  default     = "../build/function.zip"
}

variable "glm_model" {
  description = "Primary (currently free, 50 concurrent requests) GLM model for the deep-reasoning tier. glm-4-flash was retired by Z.ai."
  type        = string
  default     = "glm-5.3-flash"
}

variable "glm_base_url" {
  description = "OpenAI-compatible base URL of the Z.ai (GLM) API."
  type        = string
  default     = "https://api.z.ai/api/paas/v4"
}

variable "groq_failover_models" {
  description = "Ordered Groq failover models for the main tier (llama-3.x was shut down for free tiers on 2026-08-16; gpt-oss models are the official replacements, 30 RPM / 1K req/day each on the free tier)."
  type        = list(string)
  default     = ["openai/gpt-oss-120b", "openai/gpt-oss-20b"]
}

variable "groq_secondary_model" {
  description = "Groq model used for the fast secondary tier."
  type        = string
  default     = "openai/gpt-oss-20b"
}

variable "groq_base_url" {
  description = "OpenAI-compatible base URL of the Groq API."
  type        = string
  default     = "https://api.groq.com/openai/v1"
}

variable "glm_api_key" {
  description = "Initial GLM API key value. Rotate via `gcloud secrets versions add GLM_API_KEY` in production."
  type        = string
  default     = "REPLACE_ME_VIA_GLCLOUD"
  sensitive   = true
}

variable "groq_api_key" {
  description = "Initial Groq API key value. Rotate via `gcloud secrets versions add GROQ_API_KEY` in production."
  type        = string
  default     = "REPLACE_ME_VIA_GLCLOUD"
  sensitive   = true
}
