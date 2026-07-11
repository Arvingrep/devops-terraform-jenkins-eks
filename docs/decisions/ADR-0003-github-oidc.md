# ADR-0003: GitHub → AWS Authentication

**Status:** Proposed — not yet implemented

## Context

`Jenkinsfile` currently injects long-lived `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` as Jenkins credentials to run Terraform. The requirements (§7) call for GitHub Actions to use OIDC federation to per-environment IAM roles (`WCDTerraformLabRole`, `WCDTerraformProdPlanRole`, `WCDTerraformProdApplyRole`) instead of static keys, for any CI/CD path that ends up living in GitHub Actions rather than Jenkins.

## Decision

Not yet implemented — `.github/workflows/terraform-check.yml` (this PR) needs no AWS credentials at all (`fmt`/`validate` only with `-backend=false`), so this ADR only becomes load-bearing starting at Phase 5 (`lab-plan`/`lab-apply`/`lab-destroy`/`prod-plan` workflows) or if the ADR-0002 backend decision resolves to HCP Terraform Cloud with GitHub Actions as the trigger. `bootstrap/github-oidc/` is scaffolded as a placeholder now so the target layout is visible, but contains no working Terraform yet.

## Open question

Whether Jenkins (existing, being kept and hardened per `modules/jenkins`) or GitHub Actions (net-new) is the system of record for running `plan`/`apply` going forward — or both, for different environments. This affects whether OIDC-to-AWS is even the right mechanism for Jenkins specifically (Jenkins would more likely use an EC2 instance profile than OIDC). Needs a decision before Phase 5.
