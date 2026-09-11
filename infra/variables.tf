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

variable "ai_providers" {
  description = "Registered LLM providers with their OpenAI-compatible endpoints and initial secret placeholders."
  type = map(object({
    base_url    = string
    initial_key = optional(string, "REPLACE_ME_VIA_GLCLOUD")
  }))
  default = {
    glm = {
      base_url = "https://api.z.ai/api/paas/v4"
    }
    groq = {
      base_url = "https://api.groq.com/openai/v1"
    }
    gemini = {
      base_url = "https://generativelanguage.googleapis.com/v1beta/openai"
    }
    gemini_paid = {
      base_url = "https://generativelanguage.googleapis.com/v1beta/openai"
    }
    openrouter = {
      base_url = "https://openrouter.ai/api/v1"
    }
  }
}

variable "chain_main" {
  description = "Ordered main-tier failover chain, walked left to right. Each entry defines the provider key and model slug."
  type = list(object({
    provider = string
    model    = string
  }))
  default = [
    { provider = "glm", model = "glm-5.3-flash" },
    { provider = "groq", model = "openai/gpt-oss-120b" },
    { provider = "groq", model = "openai/gpt-oss-20b" },
    { provider = "openrouter", model = "nvidia/nemotron-3-super-120b-a12b:free" },
    { provider = "gemini", model = "gemini-3.7-flash" },
    { provider = "gemini_paid", model = "gemini-3.7-flash" },
  ]

  validation {
    condition     = length(var.chain_main) > 0
    error_message = "chain_main must contain at least one failover target."
  }

  validation {
    condition = alltrue([
      for item in var.chain_main : length(trimspace(item.provider)) > 0 && length(trimspace(item.model)) > 0
    ])
    error_message = "Each entry in chain_main must have non-empty provider and model fields."
  }
}

variable "chain_secondary" {
  description = "Ordered secondary-tier failover chain for fast chat and assistant queries."
  type = list(object({
    provider = string
    model    = string
  }))
  default = [
    { provider = "groq", model = "openai/gpt-oss-20b" },
    { provider = "groq", model = "openai/gpt-oss-120b" },
    { provider = "openrouter", model = "nvidia/nemotron-3-super-120b-a12b:free" },
    { provider = "gemini", model = "gemini-3.5-flash-lite" },
    { provider = "gemini_paid", model = "gemini-3.5-flash-lite" },
  ]

  validation {
    condition     = length(var.chain_secondary) > 0
    error_message = "chain_secondary must contain at least one failover target."
  }

  validation {
    condition = alltrue([
      for item in var.chain_secondary : length(trimspace(item.provider)) > 0 && length(trimspace(item.model)) > 0
    ])
    error_message = "Each entry in chain_secondary must have non-empty provider and model fields."
  }
}
