# AI Gateway Infrastructure (`elevate-infrastructure`)

Declarative OpenTofu configuration and automated GitHub Actions CI/CD for a
**keyless, authless, zero-cost serverless AI gateway** on Google Cloud.

The gateway protects LLM endpoints with **Firebase App Check** (hardware
attestation via Google Play Integrity / Apple App Attest), keeps API keys out
of client binaries by mounting them from **GCP Secret Manager**, and fails
over from **GLM** (free Flash tier) to **Groq** (free dev tier) within a
single request.

```
[ GitHub Actions ] ──(keyless via WIF)──▶ [ OpenTofu ]
                                               │
            ┌──────────────────────────────────┼─────────────────────────────┐
            ▼                                  ▼                             ▼
 [ Artifact Registry ]              [ Secret Manager ]             [ Cloud Functions 2nd gen ]
 (auto-pruned < 0.5 GB)             - GLM_API_KEY                  (Node.js 22, scale-to-zero)
                                    - GROQ_API_KEY                 - App Check enforcement
                                                                   - Model routing & failover
```

## Model tiers & multi-provider failover chains

The gateway implements generic, env-driven failover chains (`AI_CHAIN_MAIN`, `AI_CHAIN_SECONDARY`) walking left-to-right on HTTP 402/404/408/429/5xx and timeouts (8s per attempt, 25s total budget).

| Tier | Failover chain (walked left to right) | Cost Profile |
| :--- | :--- | :--- |
| **`main`** | `glm:glm-5.3-flash` → `groq:openai/gpt-oss-120b` → `groq:openai/gpt-oss-20b` → `openrouter:nvidia/nemotron-3-super-120b-a12b:free` → `gemini:gemini-3.7-flash` (free key) → `gemini_paid:gemini-3.7-flash` (paid fallback) | **100% Free** for links 1–5; link 6 is the ultimate emergency fallback |
| **`secondary`** | `groq:openai/gpt-oss-20b` → `groq:openai/gpt-oss-120b` → `openrouter:nvidia/nemotron-3-super-120b-a12b:free` → `gemini:gemini-3.5-flash-lite` (free key) → `gemini_paid:gemini-3.5-flash-lite` (paid fallback) | **100% Free** for links 1–4; link 5 is the ultimate emergency fallback |

## Model selection & rate limits (verified 2026-09)

- **GLM (`glm-5.3-flash`)**: Free tier on Z.ai with 50 concurrent requests. Fails over immediately on balance exhaustion (HTTP 402) or concurrency throttling (429).
- **Groq (`openai/gpt-oss-120b`, `openai/gpt-oss-20b`)**: Groq free tier with 30 RPM / 1,000 RPD per model ($0.00).
- **OpenRouter (`nvidia/nemotron-3-super-120b-a12b:free`)**: Active 120B model under OpenRouter's `:free` lineup ($0.00).
- **Gemini Free (`GEMINI_API_KEY`)**: Google AI Studio key created in an unbilled Google project (15 RPM / 1,500 RPD free tier, $0.00).
- **Gemini Paid (`GEMINI_PAID_API_KEY`)**: Attached to Firebase Blaze billing as the last-resort emergency backstop. Only reached if all preceding free providers fail.

Gateway request/response:

```jsonc
// POST /  (header: X-Firebase-AppCheck: <token>)
{ "modelTier": "main" | "secondary", "prompt": "..." }   // or "messages": [{ "role": "...", "content": "..." }]

// 200 OK
{ "reply": "...", "modelUsed": "glm-4-flash", "provider": "glm" | "groq-backup" | "groq-secondary" }
```

Requests without a valid, non-replayed App Check token are rejected with
`401/403` at the gateway. Per-user daily quotas (Pro: 25–30/day,
Free: 2–10/day) remain client-enforced as today, and the gateway adds a
best-effort 3 req/min burst throttle to protect the free GLM concurrency.

## Repository layout

```
.
├── .github/workflows/tofu-plan.yml   # PR checks: type-check, fmt, validate, plan (+ PR comment)
├── .github/workflows/tofu-apply.yml  # main push: package, deploy via WIF
├── functions/                        # Node.js 22 gateway source (TypeScript)
├── infra/                            # OpenTofu manifests
│   ├── backend.tf                    #   GCS remote state (US multi-region bucket)
│   ├── versions.tf                   #   provider pinning (google ~> 6.0)
│   ├── variables.tf                  #   project, region, models, initial key values
│   ├── iam.tf                        #   WIF pool/provider, deployer + runtime SA, bindings
│   ├── main.tf                       #   registry cleanup, secrets, source bucket, function
│   └── outputs.tf                    #   gateway URL + GitHub Actions variables
├── scripts/bootstrap.sh              # one-time: APIs + state bucket (cannot live in tofu)
└── Makefile
```

## Authentication (works locally *and* in GitHub Actions)

**There are no long-lived keys anywhere.** Two complementary flows:

| Context          | Auth flow                                                                 |
| ---------------- | ------------------------------------------------------------------------- |
| Local (human)    | `gcloud auth application-default login` → OpenTofu uses your user credentials for the GCS backend and the Google provider. Run as a project owner. |
| GitHub Actions   | OIDC token → **Workload Identity Federation** → `ai-gateway-deployer` SA. Configured via two *variables* (`WIF_PROVIDER`, `DEPLOY_SA`) — no GitHub secrets. |

The **state bucket** is the only resource that cannot be managed by OpenTofu
(it holds the state), hence the one-time bootstrap:

```bash
./scripts/bootstrap.sh <PROJECT_ID>   # enables APIs, creates US multi-region state bucket
```

First provisioning runs **locally** (owner credentials) because it creates the
WIF pool itself — the chicken-and-egg of keyless CI:

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # set project_id
tofu init
tofu apply          # creates WIF, deployer SA, registry, secrets, gateway
```

Then wire up CI from the outputs (no secrets to store):

```bash
gh variable set WIF_PROVIDER -b "$(cd infra && tofu output -raw workload_identity_provider)"
gh variable set DEPLOY_SA    -b "$(cd infra && tofu output -raw deployer_service_account)"
```

From now on: PRs touching `infra/**` or `functions/**` get a fmt/validate/plan
check with a plan summary comment, and pushes to `main` deploy automatically.

## Zero-cost footprint

| Resource              | Free tier coverage                                                        |
| --------------------- | ------------------------------------------------------------------------- |
| Cloud Functions 2nd gen / Cloud Run (prod & dev) | 2M invocations, 400K GB-s, 200K GHz-s per month, scale-to-zero |
| Secret Manager        | 6 active secret versions (we use exactly 5: GLM, Groq, OpenRouter, Gemini Free, Gemini Paid) |
| Artifact Registry     | 0.5 GB, kept below cap by KEEP(2) / delete-untagged(1d) / delete-old(7d)  |
| Cloud Storage (US)    | 5 GB-month Standard + 5k Class-A / 50k Class-B ops (state + source zips)  |
| Workload Identity     | Free                                                                       |
| AI Model Free Tiers   | GLM-5.3-Flash, Groq gpt-oss, OpenRouter :free, Gemini Free Tier (15 RPM / 1,500 RPD) |

## Rotating API keys

The initial secret versions are placeholders so the first deployment succeeds.
Set the real values once and on every rotation (no redeploy needed — the
function reads `latest`):

```bash
gcloud secrets versions add GLM_API_KEY --project <PROJECT_ID> --data-file=-
gcloud secrets versions add GROQ_API_KEY --project <PROJECT_ID> --data-file=-
gcloud secrets versions add OPENROUTER_API_KEY --project <PROJECT_ID> --data-file=-
gcloud secrets versions add GEMINI_API_KEY --project <PROJECT_ID> --data-file=-
gcloud secrets versions add GEMINI_PAID_API_KEY --project <PROJECT_ID> --data-file=-
```

## App Check registration (one-time, in Firebase console)

1. Enable the **Firebase App Check API** (done by `bootstrap.sh`).
2. Register the Android app (Play Integrity) and iOS app (App Attest) under
   Firebase → App Check.
3. Point the mobile client at `tofu output -raw gateway_url`, sending the
   App Check token in the `X-Firebase-AppCheck` header.

## Verification checklist (issue #805)

- [x] All cloud resources declared in OpenTofu; CI authenticates via WIF only.
- [x] No service account keys, API keys, or bearer tokens in the repo.
- [x] Gateway rejects requests without valid App Check attestation (`401/403`).
- [x] `main` tier routes GLM-4-Flash → Groq 70B on 429/503/504; `secondary`
      tier goes straight to Groq 8B Instant.
- [x] Artifact Registry cleanup keeps storage under the 0.5 GB free cap.
- [ ] End-to-end runs after the first local `tofu apply` + push to `main`
      (needs the real GCP project + API keys).
