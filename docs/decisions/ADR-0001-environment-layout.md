# ADR-0001: Environment Layout

**Status:** Accepted

## Context

The repository previously had no environment concept at all — one flat state per Terraform root, one set of hardcoded variables (`part1-jenkins-from-terraform/terraform.tfvars`). The requirements call for `lab`/`staging`/`prod`, each with independent state, IAM boundary, CIDR range, tags, and secrets, sharing one set of versioned modules.

## Decision

Adopt `environments/{lab,staging,prod}/` as thin composition roots (module calls + `.tfvars` + backend/provider config only, no inline resources). `staging` is scaffolded from day one (empty, documented) but not populated until after `lab` and `prod` are both working, per requirements §5.1 MVP guidance (`lab` + `prod` first).

## Consequences

- Every environment gets its own `terraform.tfvars` and its own state — no workspace-name-only isolation (explicitly disallowed by requirements §5.1).
- Adding a new environment means adding a new `environments/<name>/` directory that calls the same modules, not forking module code.
- Module interfaces must stay generic enough to serve lab-cheap and prod-hardened configs from the same source.
