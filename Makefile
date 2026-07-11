.PHONY: fmt validate lint security-scan check \
        lab-plan lab-apply lab-destroy \
        staging-plan staging-apply staging-destroy \
        prod-plan

# --- static checks: no AWS credentials required ---------------------------

fmt:
	terraform fmt -recursive

fmt-check:
	terraform fmt -check -recursive -diff

validate:
	./scripts/validate.sh

lint:
	tflint --recursive

security-scan:
	tfsec .

check: fmt-check validate

# --- environment lifecycle -------------------------------------------------
# Thin wrappers around scripts/infra.sh. See docs/deployment.md and
# docs/destroy.md once those exist; for now see docs/migration-plan.md for
# when each environment has real module calls to plan/apply/destroy.

lab-plan:
	./scripts/infra.sh lab plan

lab-apply:
	./scripts/infra.sh lab apply

lab-destroy:
	./scripts/infra.sh lab destroy

staging-plan:
	./scripts/infra.sh staging plan

staging-apply:
	./scripts/infra.sh staging apply

staging-destroy:
	./scripts/infra.sh staging destroy

# Production only ever plans through this Makefile — apply/destroy are
# human-approved actions outside of make (requirements §10.4).
prod-plan:
	./scripts/infra.sh prod plan
