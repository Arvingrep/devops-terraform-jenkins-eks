# network module

**Status:** implemented (Migration Plan Phase 2 / prerequisite for Phase 4b-1). Replaces both hand-rolled VPC blocks in `part1-jenkins-from-terraform/vpc.tf` and `part2-cluster-from-terraform-and-jenkins/terraform-for-cluster/vpc.tf`, and the unpinned `terraform-aws-modules/vpc/aws` call in part2 — this module hand-rolls dedicated VPC resources instead of wrapping that upstream module, so the interface stays exactly as small as `docs/target-architecture.md` §5 specifies.

## What this creates

- One VPC, DNS support + hostnames enabled.
- Public and private subnets, one pair per entry in `availability_zones`.
- One Internet Gateway, with a default route from every public subnet.
- NAT gateway(s) — either one shared gateway (`single_nat_gateway=true`, Lab default, cheapest) or one per AZ (`single_nat_gateway=false`) — with a default route from every private subnet, when `enable_nat_gateway=true`.
- Optional VPC flow logs to a dedicated CloudWatch Logs group, via a least-privilege IAM role scoped to only that log group's ARN (`enable_vpc_flow_logs=true`).

**Not created:** no `aws_default_security_group` / `aws_default_route_table` management (docs/target-architecture.md §5 — this module never touches the VPC's implicit default SG/route table, so it stays composable and doesn't fight AWS's implicit defaults). No security groups at all — those belong to the workload modules (`modules/eks`, `modules/jenkins`) that actually need them.

## Interface

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
| `additional_subnet_tags` | no | `{}` | merged onto every public+private subnet — e.g. `kubernetes.io/cluster/<name>`, `karpenter.sh/discovery` once an EKS cluster consuming this network exists. Kept generic here so this module doesn't need to know about any specific cluster. |

Standard tags (`Project`/`Environment`/`ManagedBy`/`Owner`/`CostCenter`/`AutoDestroy`) are **not** set by this module — they come from the calling root module's `provider "aws" { default_tags {...} }` block (see `environments/lab/providers.tf`) and apply to every resource this module creates automatically.

See `docs/target-architecture.md` §5 for the target interface this implements, and `docs/migration-plan.md` Phase 2 for why this exists as its own module rather than being folded into `modules/eks`.
