# ADR-0002: Terraform State Backend

**Status:** Proposed — pending your confirmation, see `docs/target-architecture.md` §3

## Context

Current backend (`mubin-devops-cicd-terraform-eks` S3 bucket, no DynamoDB lock table, no environment separation, hardcoded in two `backend.tf` files) is not owned by this org and has no locking. Independently of that problem, an HCP Terraform Cloud workspace (`operationarvin/infra-aws/devops-terraform-jenkins-eks`) was connected to this repo this session, with `execution-mode=local` and `auto-apply=false` — nothing in the repo points at it yet.

## Options

**A. Self-managed S3 + DynamoDB** (`bootstrap/backend/`): full control, matches requirements §6.1 literally (`wcd-infra-state/<env>/platform/terraform.tfstate` path convention), but requires building and maintaining the bootstrap module ourselves, plus a chicken-and-egg problem (backend for the backend).

**B. HCP Terraform Cloud workspaces per environment**: versioning, encryption, and locking are provided by the platform; already half-connected. Requires creating `-lab`/`-staging`/`-prod` sibling workspaces (or reusing the existing one as `lab` and adding more later) and deciding `execution-mode` (`local` keeps applies on a human's machine or in GitHub Actions with a Terraform Cloud token; `remote` moves plan/apply execution into HCP Terraform itself and is required for HCP-native VCS-triggered runs and Sentinel policy checks later).

## Decision

Not yet finalized. Recommendation is **B**, using the existing workspace as the `lab` backend, because it removes an entire bootstrap module from scope and the user has already provisioned it. This ADR stays "Proposed" until confirmed; Phase 1 of `docs/migration-plan.md` is blocked on this decision.

## Consequences (if B is confirmed)

- `bootstrap/backend/` in the target layout becomes optional/unused for now; `bootstrap/github-oidc/` may still be needed if GitHub Actions plans against these workspaces.
- One HCP Terraform workspace per environment, named consistently with the `wcd-<project>-<environment>` convention.
- Prod approval can be enforced either via HCP Terraform's own run-approval workflow or a GitHub Environment gate wrapping a `terraform-cloud`-backed apply — needs a follow-up ADR once CI (Phase 5) is designed.
