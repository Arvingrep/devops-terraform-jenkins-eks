# ADR-0004: Lab/Prod Strategy

**Status:** Accepted

## Context

Requirements explicitly forbid two permanently-diverging Lab/Prod Terraform codebases (requirements §2.2/§10.4 framing: "复用同一套 Terraform Modules，通过不同 Environment Configuration 部署 Lab、Staging 和 Production").

## Decision

`modules/*` are the single source of truth for resource logic. `environments/lab`, `environments/staging`, `environments/prod` differ only in: `.tfvars` values, backend/state target, IAM role used to apply, and which optional module features are turned on (e.g. `enable_vpc_flow_logs`, `capacity_type`, `cluster_endpoint_public_access_cidrs`). No environment is allowed to fork a module's `.tf` files locally — a lab-only need becomes a new module variable with a lab-appropriate default, not a copy.

## Consequences

- Every module variable added for "Lab needs this" must also have a sane Prod default (or be a required variable with no default, forcing an explicit Prod decision) — never silently defaulted to Lab's cheap/open setting.
- Reviewing a module change means reasoning about its effect on all three environments, not just the one that motivated it.
- `main` is the only branch that can claim to be the reusable module baseline; `lab` is for integration, not a fork point for modules themselves.
