# staging environment

**Status:** not yet scaffolded.

Per ADR-0001 (MVP guidance in requirements §5.1: `lab` + `prod` first), `staging` is deliberately left as documentation-only until `lab` and `prod` are both working end-to-end against the shared modules. When it is scaffolded, it will mirror `environments/lab/` and `environments/prod/` exactly (`versions.tf`, `providers.tf`, `variables.tf`, `outputs.tf`, `main.tf`, `terraform.tfvars.example`, `backend.hcl.example`) with its own state and IAM boundary — never a copy of Lab's or Prod's tfvars.
