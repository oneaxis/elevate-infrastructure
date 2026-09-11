# AGENTS.md - Agent & Architecture Guide for `elevate-infrastructure`

Welcome to the **elevate-infrastructure** codebase. This repository manages the declarative OpenTofu infrastructure, TypeScript Cloud Functions, and keyless CI/CD pipelines for the **ELVT AI Gateway** on Google Cloud Platform (project `elevate-1c1e9`).

This document records the architectural choices, security model, zero-cost guarantees, and operational procedures for AI agents and human developers.

---

## 1. Project Overview & Architecture

The gateway is a serverless, keyless, and authless public reverse proxy that mediates AI chat requests between the ELVT mobile application (Flutter) and multiple upstream LLM providers.

```
[ ELVT App (Flutter) ]
       │
       │ (HTTPS POST + X-Firebase-AppCheck token)
       ▼
[ Cloud Functions 2nd Gen / Cloud Run ]
  ├── 1. App Check attestation verification (verifyToken with consume: true)
  ├── 2. In-memory burst protection (3 req/min)
  ├── 3. Generic model router & failover ladder
  └── 4. Provider keys mounted from Secret Manager (runtime SA only)
       │
       ├── (1) Z.ai / GLM (glm-5.3-flash) ───[ 402/429 / Outage ]───┐
       ├── (2) Groq (gpt-oss-120b, gpt-oss-20b) ◄────────────────────┘
       ├── (3) OpenRouter (nvidia/nemotron-3-super-120b-a12b:free)
       ├── (4) Google Gemini Free (unbilled AI Studio project key, 15 RPM)
       └── (5) Google Gemini Paid (Firebase Blaze project key - EMERGENCY BACKSTOP)
```

### Core Architecture Components
- **Serverless Runtime**: Google Cloud Functions 2nd gen (backed by Cloud Run) running Node.js 22.
- **Infrastructure as Code**: OpenTofu (`>= 1.8.0`) targeting the `hashicorp/google` provider (`~> 6.0`).
- **Remote State**: Google Cloud Storage (`elevate-ai-gateway-tofu-state`, US multi-region).
- **CI/CD**: GitHub Actions using **Workload Identity Federation (WIF)** for keyless authentication.

---

## 2. Environment & Tooling Paths

When executing shell commands on this machine, use the following paths:
- **Node.js & npm**: `/home/oneaxis/.nvm/versions/node/v24.20.0/bin`
- **OpenTofu**: `/usr/bin/tofu`
- **Google Cloud SDK (`gcloud`)**: `/home/oneaxis/development/google-cloud-sdk/bin/gcloud`
- **GitHub CLI (`gh`)**: `/home/oneaxis/.local/bin/gh`
- **GCP Target Project**: `elevate-1c1e9` (Project Number `97165394176`, Region `us-central1`)

---

## 3. Key Architectural Choices

### A. Zero-Cost Footprint Constraint
**Rule**: All baseline operations must remain 100% free ($0.00).
1. **Compute (Cloud Run)**: `min_instance_count = 0` (scale-to-zero). Memory is capped at 256MB. Both prod and dev stay well inside the 2,000,000 free requests/month and 360,000 GB-seconds/month.
2. **Storage**: US multi-region GCS bucket (`elevate-1c1e9-ai-gateway-source`) inside the 5 GB-month Always Free tier. Zip archives are auto-deleted after 7 days via bucket lifecycle rules.
3. **Secret Manager**: GCP offers **6 active secret versions free** per billing account per month. We maintain exactly **5 active versions** (1 version per secret):
   - `GLM_API_KEY`
   - `GROQ_API_KEY`
   - `OPENROUTER_API_KEY`
   - `GEMINI_API_KEY` (Free-tier key)
   - `GEMINI_PAID_API_KEY` (Paid emergency key)
   *Whenever rotating keys, older versions must be destroyed via `gcloud secrets versions destroy <V>` to never exceed the 6-version limit.*
4. **AI Provider Tiering**:
   - **GLM (Z.ai)**: Free Flash tier (50 concurrent requests). Fails over on balance exhaustion (402) or concurrency limit (429).
   - **Groq**: 100% free tier (30 RPM / 1,000 RPD per model).
   - **OpenRouter**: `:free` models (no balance required, zero cost).
   - **Gemini Free**: Generated in an **unbilled** Google AI Studio project (15 RPM / 1,500 RPD free quota, $0.00).
   - **Gemini Paid**: Only reached if all 5 preceding free links fail.

### B. Multi-Provider Failover Chains
All supported LLM providers expose OpenAI-compatible `/chat/completions` endpoints.
The gateway implementation in `functions/src/index.ts` is provider-agnostic and env-driven:
- `{PROVIDER}_BASE_URL`: Base URL for the OpenAI-compatible endpoint.
- `{PROVIDER}_API_KEY`: Mounted from Secret Manager as `latest`.

#### Active Chains
- **Main Tier (`AI_CHAIN_MAIN`)**:
  `glm:glm-5.3-flash` → `groq:openai/gpt-oss-120b` → `groq:openai/gpt-oss-20b` → `openrouter:nvidia/nemotron-3-super-120b-a12b:free` → `gemini:gemini-3.7-flash` → `gemini_paid:gemini-3.7-flash`
- **Secondary Tier (`AI_CHAIN_SECONDARY`)**:
  `groq:openai/gpt-oss-20b` → `groq:openai/gpt-oss-120b` → `openrouter:nvidia/nemotron-3-super-120b-a12b:free` → `gemini:gemini-3.5-flash-lite` → `gemini_paid:gemini-3.5-flash-lite`

#### Failover Policy
- **Failover Statuses**: `402` (balance exhaustion), `404` (retired model slug), `408` (timeout), `429` (rate limit/concurrency), and `5xx` (upstream outage).
- **Fast Fail Statuses**: `401`, `403`, and `400` fail immediately without retrying (they signify configuration bugs or invalid client bodies).
- **Timeouts**: `UPSTREAM_TIMEOUT_MS = 8000` (8s per attempt). `TOTAL_BUDGET_MS = 25000` (25s total request budget, safely under the 30s Cloud Function timeout).

### C. Dual Environment & GitOps Staging Pipeline
Declared via root module instantiations of the `./gateway` submodule and deployed via branch-aware CI/CD:
- **`dev` Branch (`module.dev` / `ai-gateway-dev`)**:
  - Live dev endpoint: `https://ai-gateway-dev-97165394176.us-central1.run.app`
  - Push to `dev` triggers GitHub Actions CI which runs `tofu apply -target=module.dev`, deploying strictly to development without touching production.
  - Mobile client targets dev builds via `--dart-define=ELVT_AI_GATEWAY_URL=<url>`.
- **`main` Branch (`module.prod` / `ai-gateway`)**:
  - Live production endpoint: `https://ai-gateway-97165394176.us-central1.run.app`
  - Changes are promoted from `dev` to `main` via Pull Request.
  - PR checks run `tofu plan` showing exact infrastructure changes.
  - Merging the PR to `main` runs full `tofu apply` in GitHub Actions.
- Both environments share the source bucket and Secret Manager secrets to strictly preserve zero-cost guarantees.

### D. Security & Ingress Model
- **Authless & Keyless Ingress**: Cloud Run services have `roles/run.invoker` granted to `allUsers`. No GCP credentials or service account keys are exposed to the client.
- **Firebase App Check Enforcement**: Every request must carry a valid `X-Firebase-AppCheck` header. The function validates and consumes the token:
  ```ts
  await getAppCheck().verifyToken(appCheckToken, { consume: true });
  ```
  Consuming the token defeats replay attacks.
- **Client Burst Throttling**: An in-memory sliding window allows at most 3 requests per minute per App Check token to protect free provider quotas.
- **Execution Identity**: The function executes as `ai-gateway-runtime@elevate-1c1e9.iam.gserviceaccount.com`. It is the **only** identity granted `roles/secretmanager.secretAccessor` on the provider keys.

### E. OpenTofu & Cloud Run Gotcha
In Cloud Functions 2nd gen, the HTTPS endpoint is served directly by Cloud Run. Granting `roles/cloudfunctions.invoker` on the function resource is insufficient for direct HTTP calls. The `./gateway` module explicitly includes:
```hcl
resource "google_cloud_run_service_iam_member" "public_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.gateway.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
```

---

## 4. Operational Rules for Agents

1. **NEVER Touch Production Locally & Respect Branching**:
   - Production deployments are exclusively managed by GitHub Actions on merge to `main`.
   - Active development must be committed to `dev` (or feature branches merged into `dev`).
   - Local testing and manual applies must target the dev module:
     ```bash
     tofu apply -target=module.dev
     ```
2. **Always Package Before Planning**:
   - The function source zip name includes its SHA-1 hash (`filesha1()`).
   - Run `npm run package` in `functions/` prior to any `tofu plan` or `tofu apply`.
3. **Maintain Under 6 Active Secret Versions**:
   - When updating secrets, destroy obsolete versions:
     ```bash
     gcloud secrets versions destroy <OLD_VERSION> --secret=<SECRET_NAME> --project elevate-1c1e9 --quiet
     ```
   - Keep active versions across all secrets $\le 5$.
4. **State Moves vs Moved Blocks**:
   - When renaming or moving resources in modules, use `moved {}` blocks in OpenTofu.
   - If using `-target`, OpenTofu requires moving state explicitly via `tofu state mv` to avoid targeting exclusion errors.

---

## 5. Essential Commands & Verification

### Build & Package
```bash
export PATH="$HOME/.nvm/versions/node/v24.20.0/bin:$PATH"
cd functions && npm run package
```

### OpenTofu Format, Validate & Plan
```bash
cd infra
tofu fmt -check -recursive
tofu validate
tofu plan -input=false
```

### Secret Key Rotation
```bash
echo -n "<KEY>" | gcloud secrets versions add <NAME>_API_KEY --project elevate-1c1e9 --data-file=-
```

### Exchange App Check Debug Token (for testing)
```bash
TOKEN=$(curl -s -X POST \
  "https://firebaseappcheck.googleapis.com/v1/projects/elevate-1c1e9/apps/1:97165394176:web:cf3b6a2bd960c34f4733e5:exchangeDebugToken?key=AIzaSyAa0ZYEL5UPLglWMl68lK2VE2vClxyajk0" \
  -H "Content-Type: application/json" \
  -d '{"debugToken": "57dc4ec4-d2f4-4bde-9bd0-bacae2b4cf63", "limitedUse": true}' | jq -r .token)
```

### Run Verification Battery
```bash
TARGET_URL="https://ai-gateway-97165394176.us-central1.run.app"

# 401 Unauthorized (no token)
curl -i -s -X POST "$TARGET_URL" -H "Content-Type: application/json" -d '{"prompt":"hi"}'

# 403 Forbidden (bad token)
curl -i -s -X POST "$TARGET_URL" -H "Content-Type: application/json" -H "X-Firebase-AppCheck: bad" -d '{"prompt":"hi"}'

# 400 Bad Request (missing prompt)
curl -i -s -X POST "$TARGET_URL" -H "Content-Type: application/json" -H "X-Firebase-AppCheck: $TOKEN" -d '{}'

# 200 OK Secondary Tier
curl -s -X POST "$TARGET_URL" -H "Content-Type: application/json" -H "X-Firebase-AppCheck: $TOKEN" -d '{"modelTier":"secondary","prompt":"Say hi"}'

# 200 OK Main Tier Failover
curl -s -X POST "$TARGET_URL" -H "Content-Type: application/json" -H "X-Firebase-AppCheck: $TOKEN" -d '{"modelTier":"main","prompt":"Say hi"}'
```
