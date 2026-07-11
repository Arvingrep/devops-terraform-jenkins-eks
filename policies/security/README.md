# security policy definitions

**Status:** not yet implemented.

Guardrails encoding requirements §11 — no `0.0.0.0/0`, no unencrypted storage, no unpinned versions. Populated once there is a real static-scan CI step to enforce them (Migration Plan Phase 3+). Until then, `.github/workflows/terraform-check.yml` and manual `tfsec` runs (see `docs/current-state-assessment.md`) are the enforcement mechanism.
