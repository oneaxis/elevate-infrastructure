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

variable "chain_main" {
  description = "Ordered main-tier failover chain ('provider:model' entries, walked left to right). Free providers first; Gemini is billed per token if project has billing attached (or free if using an unbilled project key), so it is strictly the LAST resort; OpenRouter :free models sit before it."
  type        = string
  default     = "glm:glm-5.3-flash,groq:openai/gpt-oss-120b,groq:openai/gpt-oss-20b,openrouter:nvidia/nemotron-3-super-120b-a12b:free,gemini:gemini-3.7-flash,gemini_paid:gemini-3.7-flash"
}

variable "chain_secondary" {
  description = "Ordered secondary-tier failover chain for the fast assistant/chat tier."
  type        = string
  default     = "groq:openai/gpt-oss-20b,groq:openai/gpt-oss-120b,openrouter:nvidia/nemotron-3-super-120b-a12b:free,gemini:gemini-3.5-flash-lite,gemini_paid:gemini-3.5-flash-lite"
}

variable "provider_base_urls" {
  description = "OpenAI-compatible base URL per provider. All of them expose /chat/completions, so the gateway client stays provider-agnostic."
  type        = map(string)
  default = {
    glm         = "https://api.z.ai/api/paas/v4"
    groq        = "https://api.groq.com/openai/v1"
    gemini      = "https://generativelanguage.googleapis.com/v1beta/openai"
    gemini_paid = "https://generativelanguage.googleapis.com/v1beta/openai"
    openrouter  = "https://openrouter.ai/api/v1"
  }
}

variable "provider_initial_keys" {
  description = "Initial secret values per provider. Rotate in production via `gcloud secrets versions add <PROVIDER>_API_KEY` — the function always reads `latest`."
  type        = map(string)
  default = {
    glm         = "REPLACE_ME_VIA_GLCLOUD"
    groq        = "REPLACE_ME_VIA_GLCLOUD"
    gemini      = "REPLACE_ME_VIA_GLCLOUD"
    gemini_paid = "REPLACE_ME_VIA_GLCLOUD"
    openrouter  = "REPLACE_ME_VIA_GLCLOUD"
  }
  sensitive = true
}
