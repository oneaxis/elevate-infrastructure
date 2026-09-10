.PHONY: bootstrap init fmt fmt-check validate package plan apply outputs

bootstrap: ## One-time: enable APIs + create the US state bucket
	bash scripts/bootstrap.sh $(PROJECT_ID)

init: ## Initialize OpenTofu against the GCS remote backend
	cd infra && tofu init

fmt: ## Format all OpenTofu code
	cd infra && tofu fmt -recursive

fmt-check: ## CI-style format check
	cd infra && tofu fmt -check -recursive

validate: ## Validate OpenTofu code (requires init)
	cd infra && tofu init -input=false && tofu validate

package: ## Build + zip the TypeScript function into build/function.zip
	cd functions && npm ci && npm run package

plan: ## Plan against the remote state (requires package first)
	cd infra && tofu plan -input=false

apply: ## Apply (production deploys use GitHub Actions + WIF)
	cd infra && tofu apply -input=false

outputs: ## Show gateway URL and GitHub Actions variables
	cd infra && tofu output
