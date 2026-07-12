# network module

**Status:** implemented (Migration Plan Phase 2 / prerequisite for Phase 4b-1). Replaces both hand-rolled VPC blocks in `part1-jenkins-from-terraform/vpc.tf` and `part2-cluster-from-terraform-and-jenkins/terraform-for-cluster/vpc.tf`, and the unpinned `terraform-aws-modules/vpc/aws` call in part2 — this module hand-rolls dedicated VPC resources instead of wrapping that upstream module, so the interface stays exactly as small as `docs/target-architecture.md` §5 specifies.

## Purpose

Give every environment (`lab`/`staging`/`prod`) an isolated, EKS-capable VPC from one shared, versioned module — so network topology decisions (NAT strategy, flow logs, subnet layout) are made once in code and only differ per environment through variables, never through copy-pasted or hand-edited Terraform.

## Architecture

- One VPC, DNS support + hostnames enabled.
- Public and private subnets, one pair per entry in `availability_zones` (≥2, required for the EKS control plane that will eventually attach to this network).
- One Internet Gateway, with a default route from every public subnet.
- NAT gateway(s) — either one shared gateway (`single_nat_gateway=true`, Lab default, cheapest) or one per AZ (`single_nat_gateway=false`) — with a default route from every private subnet, when `enable_nat_gateway=true`.
- Optional VPC flow logs to a dedicated CloudWatch Logs group, via a least-privilege IAM role scoped to only that log group's ARN (`enable_vpc_flow_logs=true`).

**Not created:** no `aws_default_security_group` / `aws_default_route_table` management (`docs/target-architecture.md` §5 — this module never touches the VPC's implicit default SG/route table, so it stays composable and doesn't fight AWS's implicit defaults). **No security groups at all** — those belong to the workload modules (`modules/eks`, future `modules/jenkins`) that actually need them; this module has zero opinions about what's allowed to talk to what.

## Inputs

| Variable | Required | Default | Notes |
|---|---|---|---|
| `name_prefix` | yes | — | e.g. `wcd-platform-lab`, used for every `Name` tag |
| `vpc_cidr_block` | no | `10.0.0.0/16` | |
| `availability_zones` | yes | — | must be ≥2 (EKS control plane requirement) |
| `public_subnet_cidrs` | yes | — | one entry per `availability_zones` |
| `private_subnet_cidrs` | yes | — | one entry per `availability_zones` |
| `enable_nat_gateway` | no | `true` | |
| `single_nat_gateway` | no | `false` | Lab sets this `true` for cost |
| `enable_vpc_flow_logs` | no | `false` | |
| `flow_logs_retention_in_days` | no | `14` | only used when flow logs enabled |
| `additional_subnet_tags` | no | `{}` | merged onto every public+private subnet — e.g. `kubernetes.io/cluster/<name>` once an EKS cluster consuming this network exists (wired from `environments/lab` as of Plan-1001 Phase 1 review) |

Standard tags (`Project`/`Environment`/`ManagedBy`/`Owner`/`CostCenter`/`AutoDestroy`) are **not** set by this module — they come from the calling root module's `provider "aws" { default_tags {...} }` block (see `environments/lab/providers.tf`) and apply to every resource this module creates automatically.

## Outputs

| Output | Description |
|---|---|
| `vpc_id` | ID of the created VPC |
| `vpc_cidr_block` | CIDR block of the created VPC |
| `public_subnet_ids` | IDs of the public subnets, same order as `availability_zones` |
| `private_subnet_ids` | IDs of the private subnets, same order as `availability_zones` |
| `nat_gateway_ids` | IDs of the NAT gateway(s); empty list if `enable_nat_gateway=false` |
| `availability_zones` | Echoes the input, for callers that need to align other resources to the same AZ order |

## Dependencies

None on other modules in this repository — `modules/network` is the foundation layer. It is a dependency *of* `modules/eks` (consumes `vpc_id`/`private_subnet_ids`) and will be a dependency of `modules/jenkins` once that lands. External dependency: the `hashicorp/aws` provider, `~> 6.0` (see `versions.tf`).

## Security

- No `aws_default_security_group`/`aws_default_route_table` management (see Architecture above).
- Public subnets set `map_public_ip_on_launch=false` — only the NAT gateway lives there, and it gets its public IP from an explicit `aws_eip`, not subnet auto-assign (tfsec `aws-ec2-no-public-ip-subnet`, HIGH — found and fixed during Phase 4b-1, not an open issue).
- VPC flow log IAM role, when enabled, is scoped to exactly its own CloudWatch Logs group ARN — not `*` on `logs:*`.
- No SSH, no security groups of any kind originate here — nothing in this module could expose a port to `0.0.0.0/0` even by mistake, since it never creates an `aws_security_group`.
- Current `tfsec --minimum-severity HIGH` result: 0 findings (verified 2026-07 as part of Plan-1001 Phase 1 review, re-run against the latest commit — see PR #3 review comment).

## Cost

- VPC, subnets, route tables, Internet Gateway: **free.**
- NAT Gateway: the one real cost driver — **~$32–40/month** (Lab: single shared gateway) depending on data processing (`$0.045/GB`). Considered and rejected: a NAT instance instead (cheaper sticker price, worse reliability/ops burden — not worth it even for Lab).
- VPC flow logs: **$0** by default (`enable_vpc_flow_logs=false` in Lab) — CloudWatch Logs ingestion/storage cost only if explicitly enabled.
- Not yet implemented, worth considering if NAT data-processing cost becomes material: an S3 gateway VPC endpoint (free) to remove image-layer-pull traffic from the NAT data-processing bill.
- See Plan-1001 Phase 4 (Cost Review) for the full cross-module monthly estimate.

## Destroy Impact

- No stateful/data resources in this module (no S3 buckets, no databases) — nothing here needs a `force_destroy` flag or backup-before-destroy step.
- Natural Terraform dependency order already tears down dependents (EKS node groups, cluster ENIs) before the VPC/subnets themselves — no manual ordering required for *this* module's own resources.
- NAT Gateway + EIP release cleanly on destroy; no orphan risk specific to this module (unlike EBS volumes at the workload layer — see `docs/eks-lab-destroy.md` §"Orphan EBS check" for that separate, real risk).
- See `docs/eks-lab-destroy.md` for where this module's destroy fits into the full, ordered Lab teardown sequence (network is deliberately *last*, after workloads/PVCs/node groups/cluster).

## Validation

- `terraform fmt -check -recursive -diff`: clean.
- `tfsec --minimum-severity HIGH`: 0 findings.
- `tflint --recursive`: clean.
- `terraform validate` under the CI-pinned Terraform 1.15.8: passing (this dev environment's local Terraform is 1.5.7, below this module's `required_version`, so local `validate` can't run — CI is the source of truth here).
- **Not validated:** no `apply` has been run anywhere (no AWS credentials exist in any environment that has touched this module so far) — every check above is static analysis, not a real deployment.

## Recovery

This module holds no data of its own, so "recovery" here means re-applying from code/state, not restoring backups. The one thing that *can* change identity across a destroy/recreate: the NAT gateway's Elastic IP. Anything outside this Terraform state that allowlists a specific NAT IP (an external service's IP allowlist, for example) would need updating after a NAT gateway recreate — nothing in this module itself breaks, but downstream systems that pinned to the old IP would.

## Reuse

Designed to be called identically from every environment — `lab`, `staging` (not yet wired), and `prod` (not yet wired) all use the same `module "network" { source = "../../modules/network" ... }` block shape, differing only in `terraform.tfvars` values (CIDR ranges, `single_nat_gateway`, `enable_vpc_flow_logs`). No module code change is needed to add Prod; see Plan-1001 Phase 1 review (PR #3 comment) for exactly what that involves. The one thing *not* enforced by the module and requiring a human decision per environment: non-overlapping CIDR ranges, in case cross-environment VPC peering or Transit Gateway ever becomes a requirement.
