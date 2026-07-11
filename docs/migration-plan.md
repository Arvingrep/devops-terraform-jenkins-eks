# Migration Plan

Maps the current state (`docs/current-state-assessment.md`) to the target (`docs/target-architecture.md`) in reviewable, revertible steps. No step in this plan is executed by this PR beyond the documents and scaffolding files themselves — every Terraform-affecting step below is future work, listed here so the sequence can be reviewed before any of it happens.

## Guiding rule

Every phase that touches real Terraform resources ships as its own PR, with its own `terraform plan` output pasted into the PR description, and is never auto-merged or auto-applied by the agent doing the work.

## Phase 0 — this PR (`feature/iac-foundation` → `lab`)

**What it does:** documentation, directory skeleton, tooling config, CI lint-only workflow. Zero Terraform resources touched. The one exception: `terraform fmt -recursive` was run against `part1-jenkins-from-terraform/*` and `part2-cluster-from-terraform-and-jenkins/terraform-for-cluster/*` to make the new `terraform-check.yml` fmt gate pass — this is a whitespace/alignment-only change (`fmt` never edits resource arguments, values, or semantics) and includes fixing a pre-existing stray-space typo in `server.tf`'s output block. No resource attribute, variable value, or module argument changed.

**Old code kept as-is (semantically):** both existing part1/part2 trees keep every resource, variable, and value exactly as before — only whitespace was reformatted.
**New code added:** `docs/*`, `modules/*/README.md` placeholders, `environments/*/README.md` placeholders, `bootstrap/*/README.md` placeholders, `.gitignore` fix, `.terraform-version`, `.tflint.hcl`, `Makefile`, `scripts/infra.sh` (guards + clear "not yet implemented" errors, no real terraform calls into empty dirs), `.github/workflows/terraform-check.yml`.
**Resource impact:** none. **State impact:** none. **Rollback:** revert the PR; nothing external changes.

## Phase 1 — Bootstrap decision + backend (separate PR, no apply by the agent)

**Decision needed first (blocks this phase):** S3+DynamoDB bootstrap vs. HCP Terraform Cloud workspaces per environment — see ADR-0002. Recommendation is HCP Terraform Cloud since it's already connected; needs your confirmation before any bootstrap code is written.
**What it does:** `bootstrap/backend/` (if S3 route) or workspace-per-environment setup notes (if HCP route), plus `environments/lab/backend.hcl.example` or `cloud {}` block wiring.
**Resource impact if S3 route chosen:** creates exactly one new S3 bucket + one DynamoDB table (net-new, does not touch `mubin-devops-cicd-terraform-eks`). **If HCP route chosen:** no new AWS resources, only Terraform Cloud workspace config — but still requires a human (not the agent) to actually run `terraform login`/apply the workspace settings, per the permission boundary in `feedback_wcd_agent_permission_boundaries`.
**Rollback:** new backend, so trivially abandonable — nothing is migrated onto it yet.

## Phase 2 — Network module extraction

**What it does:** create `modules/network`, then rewrite `environments/lab/main.tf` to call it with lab-sized variables (`single_nat_gateway=true`, flow logs optional).
**Old code affected:** `part1-jenkins-from-terraform/vpc.tf` and `part2-cluster-from-terraform-and-jenkins/terraform-for-cluster/vpc.tf` are the *reference* for what the module should do — they are not edited in place; the module is new code.
**Does this replace running resources?** Only if/when someone points `environments/lab` at real AWS and applies it — until then, zero blast radius. If a already-applied VPC is later adopted into the module's address space, that requires `terraform state mv` or `import` blocks, planned resource-by-resource in that PR, never a blind `apply`.
**Force-replacement risk to flag explicitly when this PR is opened:** none for net-new lab; HIGH if ever pointed at an existing VPC without an import plan (VPC/subnet CIDR changes force replacement).

## Phase 3 — Jenkins module extraction + security fixes

**What it does:** create `modules/jenkins`; fix the `0.0.0.0/0` SSH/8080 exposure, add IMDSv2 enforcement, EBS encryption, dedicated data volume, IAM instance profile.
**Explicit flag:** if this module is ever applied on top of an *existing* Jenkins EC2 instance (rather than net-new in a fresh lab), the security-group and instance-profile changes are likely to force instance replacement (new AMI settings, new IMDS options can't always be changed in place) — Jenkins data on the root volume would be lost unless a snapshot/backup step precedes it. This must be called out again, loudly, in that PR's description before anyone applies it against a real running Jenkins box.
**Lab-only for now:** this phase only ships a lab-sized config; HA/ALB/HTTPS is explicitly deferred (target-architecture §6).

## Phase 4 — EKS module extraction

**What it does:** create `modules/eks` wrapping the upstream module with a supported Kubernetes version (current `1.24` must be bumped — likely already unsupported by AWS standard tier by now), IRSA/OIDC, restricted endpoint CIDRs, control-plane logging.
**Explicit flag:** bumping `cluster_version` on an already-applied cluster is an in-place upgrade path in EKS (not a replacement) but is a one-way door per AWS (no downgrade) — must be it's own reviewed step, never bundled silently into a module refactor.
**State impact:** net-new in lab; adopting an existing cluster needs `terraform state mv`/import planned explicitly, same rule as Phase 2.

## Phase 5 — CI/CD completion

`lab-plan.yml`, `lab-apply.yml` (manual trigger, GitHub Environment gate), `lab-destroy.yml` (manual trigger + typed confirmation + destroy-plan-then-approve, per requirements §10.3), `prod-plan.yml` (plan only, apply stays a human/console action per §10.4 until a Prod approval workflow is explicitly signed off). None of these are created until Phase 1–4 give them something real to run against.

## Cross-cutting: how "no accidental destroy" is enforced across every phase

- Every phase PR must paste a real `terraform plan` (or explain why one couldn't be generated, e.g. backend not yet decided) — never described from memory.
- Any plan line containing `destroy`, `force-replacement`, `-/+`, or IAM policy widening gets its own callout paragraph in the PR body, not buried in a diff.
- The agent doing this work does not run `apply` or `destroy` at any phase without the user explicitly asking, in that conversation, for that specific run — standing approval is never assumed from an earlier phase.
