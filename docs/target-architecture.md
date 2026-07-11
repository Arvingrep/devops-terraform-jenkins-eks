# Target Architecture

This describes where the repository is headed. It is not implemented yet — implementation happens incrementally per `docs/migration-plan.md`. See `docs/current-state-assessment.md` for the baseline this replaces.

## 1. Principles

1. One set of versioned Terraform **modules**, reused by every environment.
2. Every environment (`lab`, `staging`, `prod`) gets its own state, its own `.tfvars`, and its own IAM boundary — never a shared state file, never workspace-name-only isolation.
3. Nothing in `main` is a copy-paste fork of Lab — `main` holds modules + environment configs; drift is prevented by construction, not by discipline.
4. Lab must be cheap, disposable, and safe to destroy at any time. Prod must be auditable and require human approval to change.

## 2. Repository layout (target)

```
devops-terraform-jenkins-eks/
├── bootstrap/{backend,github-oidc}/     # one-time per-account setup, applied by a human
├── modules/{network,security,iam,jenkins,eks,ecr,observability,dns}/
├── environments/{lab,staging,prod}/     # thin: module calls + tfvars, no resource logic
├── scripts/{infra.sh,bootstrap.sh,validate.sh,cost-check.sh,smoke-test.sh}
├── policies/{iam,security,tagging}/
├── tests/{terraform,smoke}/
├── docs/{architecture,deployment,destroy,security,disaster-recovery}.md, decisions/ADR-*.md
└── .github/workflows/{terraform-check,lab-plan,lab-apply,lab-destroy,prod-plan}.yml
```

`environments/*` contain no inline resource blocks — only `module "network" { source = "../../modules/network" ... }`-style calls plus provider/backend/version pinning. All actual resource logic lives in `modules/`.

## 3. State backend — open decision, see ADR-0002

Two candidates now exist:

- **A. Self-managed S3 + DynamoDB**, per the original requirements doc: `bootstrap/backend/` creates one encrypted, versioned, public-access-blocked bucket owned by this org, with per-environment keys (`lab/platform/terraform.tfstate`, etc.) and a DynamoDB lock table.
- **B. HCP Terraform Cloud** (already provisioned this session: org `operationarvin`, project `infra-aws`, workspace `devops-terraform-jenkins-eks`, `execution-mode=local`, `auto-apply=false`): gives versioning, encryption, and locking natively, no bootstrap module needed, but requires one workspace per environment and a decision on `execution-mode` (`local` = state-only, CLI still runs the plan/apply locally; `remote` = HCP Terraform runs it, needed for real VCS-triggered CI).

**Recommendation:** adopt B for `lab` (already half-wired, zero extra bootstrap cost) and revisit for `staging`/`prod` once the OIDC/approval story (§6) is decided — HCP Terraform's own run approval can substitute for GitHub Environment approval, or the two can be layered. This is recorded as a proposed, not final, decision in ADR-0002 pending your confirmation.

## 4. Environment model

| | lab | staging | prod |
|---|---|---|---|
| AWS account | dedicated or isolated OU | dedicated | dedicated |
| State | separate (backend candidate above) | separate | separate |
| NAT | single NAT (cost) | single or per-AZ | per-AZ |
| EKS endpoint | public, unrestricted OK | public+CIDR-restricted | private + restricted public |
| Node capacity | Spot allowed, 1 min | mixed | on-demand baseline + spot burst |
| Apply trigger | manual/automatic on `lab` merge | manual | human-approved only |
| Tags | `AutoDestroy=true` mandatory | `AutoDestroy=false` | `AutoDestroy=false` |

Naming: `wcd-<project>-<environment>-<resource>` (e.g. `wcd-platform-lab-vpc`) per requirements §5.2 — pending confirmation of `wcd-platform` as the actual project slug (see open question in current session).

## 5. Network module (`modules/network`)

Replaces both existing hand-rolled `vpc.tf` files and the unpinned `terraform-aws-modules/vpc/aws` call. Interface: `enable_nat_gateway`, `single_nat_gateway`, `enable_vpc_flow_logs`, `availability_zones`, `public_subnet_cidrs`, `private_subnet_cidrs`, plus mandatory tag variables. No `aws_default_security_group`/`aws_default_route_table` usage — dedicated resources only, so the module is composable and importable across environments without fighting AWS's implicit defaults.

## 6. Jenkins module (`modules/jenkins`)

Fixes required before this graduates out of "tutorial": no SSH 22 or 8080 open to `0.0.0.0/0` (replace with a scoped CIDR variable or, longer-term, SSM Session Manager instead of SSH entirely), IMDSv2 enforced, EBS root + a dedicated encrypted data volume for `/var/lib/jenkins`, IAM instance profile scoped to only what Jenkins needs (never `AdministratorAccess`), no plaintext secrets in `user_data`, Terraform/kubectl versions pinned instead of "latest at boot". HTTPS/ALB and Jenkins-home backup are explicitly out of scope for the Lab-minimum version and tracked as follow-ups.

## 7. EKS module (`modules/eks`)

Wraps a current `terraform-aws-modules/eks/aws` version, pinned alongside a matching `required_providers { aws = { version = ... } }` constraint — confirmed necessary, not theoretical: `part2`'s current unpinned `~>19.0` module already fails `terraform validate` against today's AWS provider (`docs/current-state-assessment.md` §8a). Pinned, current-supported Kubernetes version (the existing `1.24` is past standard support by now and must be bumped), `cluster_endpoint_public_access_cidrs` restricted by variable, IRSA/OIDC enabled by default, control-plane logging on, and node group `capacity_type` selectable (`SPOT` default for lab). Advanced capabilities (Karpenter, PDBs, multi-AZ node pinning) are explicitly deferred past the first working version per requirements §8.3.

## 8. CI/CD

`terraform-check.yml` (this PR): `fmt -check -recursive`, `init -backend=false`, `validate`, on every PR, no AWS credentials needed. `lab-plan`/`lab-apply`/`lab-destroy` and `prod-plan` workflows are deferred to the module-extraction phase once `environments/lab` has real content to plan against — building them against an empty skeleton would just be a workflow that always fails.

## 9. What does not change in this PR

No AWS resources are created, modified, or destroyed by this PR. `part1-jenkins-from-terraform` and `part2-cluster-from-terraform-and-jenkins` are left in place and working exactly as before until the module-extraction PRs land and a verified `terraform state mv` plan exists (`docs/migration-plan.md`).
