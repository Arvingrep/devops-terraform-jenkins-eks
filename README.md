# devops-terraform-jenkins-eks

WCD's AWS Infrastructure-as-Code baseline: one set of versioned Terraform modules, deployed to independent `lab` / `staging` / `prod` environments, for a Jenkins CI server and an EKS cluster. It started as a tutorial project ([original article](https://medium.com/@mubin.khalife/devops-project-using-terraform-jenkins-and-eks-17d93bf28e40)) and is being restructured into a long-term, repeatable, auditable template — see `docs/current-state-assessment.md` for exactly what still needs to change and `docs/migration-plan.md` for the sequence.

**Status:** foundation phase. `modules/*` are interface stubs (see each module's `README.md`); `part1-jenkins-from-terraform/` and `part2-cluster-from-terraform-and-jenkins/` are the original, still-working tutorial code that the modules will replace. Nothing in this repo currently applies to AWS as a template — see the migration plan before running anything against a real account.

## Architecture (target)

```
                     ┌───────────────────────────┐
                     │   modules/ (versioned)    │
                     │  network · jenkins · eks  │
                     │  iam · security · ecr ·   │
                     │  observability · dns      │
                     └─────────────┬─────────────┘
                     called by, per environment
          ┌──────────────────┼──────────────────┐
          ▼                  ▼                  ▼
  environments/lab   environments/staging  environments/prod
  own state, own      (scaffolded later,    own state, own
  tfvars, cheap        ADR-0001)             tfvars, IAM-gated
  defaults                                   approval required
```

Full detail: `docs/target-architecture.md`. Decision log: `docs/decisions/ADR-*.md`.

## Directory structure

```
bootstrap/        one-time, per-account setup (human-run only)
modules/          reusable Terraform modules (network, jenkins, eks, iam, security, ecr, observability, dns)
environments/     lab / staging / prod — module calls + tfvars, no inline resources
scripts/          infra.sh, validate.sh, bootstrap.sh, cost-check.sh, smoke-test.sh
policies/         tagging / security / IAM guardrails
tests/            terraform + smoke tests
docs/             architecture, deployment, destroy, security, disaster-recovery, decisions/
.github/workflows/  CI: fmt/validate/lint/security-scan on every PR
part1-jenkins-from-terraform/                 original tutorial code (being replaced by modules/jenkins + modules/network)
part2-cluster-from-terraform-and-jenkins/     original tutorial code (being replaced by modules/eks)
```

## Prerequisites

- Terraform pinned in `.terraform-version` (currently `1.15.8`) — use `tfenv`/`asdf` or match manually.
- `tflint`, `tfsec` for local static checks (`make check`); CI runs these regardless of local install (`scripts/validate.sh` skips gracefully if they're missing locally).
- AWS credentials for whichever environment you're planning against — never long-lived keys committed to this repo (see `docs/security.md` once written; ADR-0003 tracks the OIDC-vs-instance-role decision).

## Bootstrap

One-time, per-AWS-account setup, done by a human (requirements §2.1 explicitly allows this as manual): see `bootstrap/backend/README.md` and `bootstrap/github-oidc/README.md`. Which backend option gets bootstrapped is not finalized yet — see ADR-0002 (self-managed S3+DynamoDB vs. HCP Terraform Cloud workspaces; an HCP Terraform Cloud workspace is already connected to this repo as of this writing).

## Lab: deploy

Not runnable yet — `environments/lab/main.tf` has no module calls until Migration Plan Phase 2 lands. Target commands once it does:

```bash
make lab-plan
make lab-apply
```

or equivalently `./scripts/infra.sh lab plan|apply`. `scripts/infra.sh` refuses to run until `environments/lab` has real module calls and a `terraform.tfvars` (copied from `terraform.tfvars.example`).

## Lab: destroy

```bash
make lab-destroy
```

Generates a destroy plan, requires typing `destroy-lab` to confirm, then runs `terraform destroy` (`scripts/infra.sh`). See `docs/destroy.md` (to be written) for the residual-resource checklist (NAT Gateway, EBS, ELB/NLB, Elastic IP — requirements §9).

## Production change process

`main` never takes direct commits. Every change is a PR: `terraform fmt`/`validate`/`tflint`/`tfsec` in CI (`terraform-check.yml`), a `terraform plan` attached to the PR, then human approval before `apply` — `prod-plan` runs in CI, `prod-apply` is never run by an automated agent (requirements §10.4). See `docs/migration-plan.md` for how each module/environment gets there.

## Terraform state

Two backend candidates are open (ADR-0002): self-managed S3+DynamoDB, or the HCP Terraform Cloud workspace already connected (`operationarvin/infra-aws/devops-terraform-jenkins-eks`, currently `execution-mode=local`, `auto-apply=false` — pushing to this repo does not trigger a remote run today). Each environment gets fully independent state; `lab` and `prod` never share a backend key or workspace.

## AWS authentication

Target: GitHub Actions → OIDC → per-environment IAM role (`WCDTerraformLabRole`, `WCDTerraformProdPlanRole`, `WCDTerraformProdApplyRole` — ADR-0003), no long-lived `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`. The existing `Jenkinsfile` still uses Jenkins-credential-injected static keys today — tracked as a gap in `docs/current-state-assessment.md`, not yet fixed.

## Cost

Lab is tagged `AutoDestroy=true` and defaults to the cheapest viable shapes (single NAT gateway, small on-demand/spot instances). `scripts/cost-check.sh` wraps Infracost when available and is explicitly non-blocking if it isn't installed (requirements §9). Watch NAT Gateway, EKS control plane, EC2/EBS, and any ELB/NLB left behind after a failed destroy.

## Security

No `0.0.0.0/0` on SSH/Jenkins/EKS endpoint is the baseline (current code violates this — see `docs/current-state-assessment.md` §5 for the exact `tfsec` findings this repo starts from). `docs/security.md` (to be written) will hold the full checklist; ADRs hold the reasoning for each structural security decision.

## Troubleshooting

Start with `docs/current-state-assessment.md` (what's true today), `docs/target-architecture.md` (where it's going), and `docs/migration-plan.md` (how, and in what order, with rollback notes per phase). `docs/destroy.md` and `docs/disaster-recovery.md` are not written yet — tracked as follow-up docs.
