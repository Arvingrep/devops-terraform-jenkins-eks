# eks module

**Status:** implemented for Migration Plan Phase 4b-1 ("EKS Lab Foundation") only. Wraps `terraform-aws-modules/eks/aws` with a supported Kubernetes version, a single `system-on-demand` managed node group, and a fixed set of core addons. Built against `docs/eks-capacity-plan.md`, `docs/eks-node-group-design.md`, `docs/eks-scheduling-standard.md`, and `docs/eks-storage-design.md` (Phase 4a), which were the gating prerequisite for this module (`docs/migration-plan.md` Phase 4a → 4b).

## Purpose

Give Lab a minimal, reproducible, fully-destroyable EKS cluster from one shared module — cluster, one node group, and the four core addons every real cluster needs, with nothing beyond that. Everything not needed to get a working cluster (Karpenter, Spot, stateful storage, observability, applications) is explicitly deferred, not half-built.

## Architecture

One EKS cluster (private endpoint by default) + one EKS Managed Node Group (`system`, On-Demand, arm64) + four addons (`vpc-cni`, `coredns`, `kube-proxy`, `aws-ebs-csi-driver`) + the EBS CSI driver's own least-privilege IAM role via Pod Identity. See the dedicated sections below for the reasoning behind each of these choices — they're not arbitrary defaults, each one was verified against current documentation (no live AWS account exists in this environment to verify against instead).

## Explicitly out of scope for this version of the module

Karpenter NodePools (`stateless-on-demand`/`stateless-spot`/`batch-spot`), Spot capacity, `stateful-*` node groups, VPA, any application/observability workload, Production. See `docs/eks-node-group-design.md` for the full node pool design these will land against later — this module intentionally does not expose a Karpenter NodePool interface yet.

## Kubernetes version

**Selected: 1.35.** Verification source: [AWS EKS kubernetes-versions-standard](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html). Verification date: 2026-07-12.

Rationale: AWS standard support at verification time covers 1.33/1.34/1.35/1.36. 1.33's standard support ends 2026-07-29 (days away); 1.34 follows a few months later; 1.36 was only released ~April 2026 and carries several breaking changes (permanent `gitRepo` volume removal, strict IP/CIDR validation). 1.35 has the longest remaining standard-support runway of the non-bleeding-edge options and is one release behind the newest for maturity.

This is a `var.cluster_version` **input**, not hardcoded — `environments/lab` sets it to `"1.35"` today; bumping it later is a version-controlled, reviewed change to that one line, not a module change.

## Architecture: arm64

`system-on-demand` defaults to **arm64** (`m7g.large`), per `docs/eks-node-group-design.md`'s default preference. Confirmed via public documentation (not a live AWS account — none is configured in this environment) that every component this PR installs supports `linux/arm64`: VPC CNI, CoreDNS, kube-proxy, and the EBS CSI driver are all long-standing multi-arch images, and AWS publishes an official `AL2023_ARM_64_STANDARD` EKS-optimized AMI. `var.system_node_group.architecture` is a required, explicit field (`"arm64"` or `"amd64"`, validated) — the caller must state it, this module never picks silently. Switch to `"amd64"` per node group by changing that one field if a real workload later turns out to need it.

## IAM: EKS Pod Identity, not IRSA

The EBS CSI driver's IAM role trusts `pods.eks.amazonaws.com` (Pod Identity) rather than the cluster OIDC provider (IRSA) — AWS's current default recommendation for new addon IAM wiring. The role gets exactly the AWS-managed `AmazonEBSCSIDriverPolicy`, nothing broader. `enable_irsa` on the underlying module is left at its default (`true`), so the OIDC provider still exists and is exposed via `oidc_provider_arn` for anything that needs IRSA later — this module's own addon wiring just doesn't use it.

`eks-pod-identity-agent` is installed automatically whenever `aws-ebs-csi-driver` is in `var.cluster_addons` — it isn't a separate item in `var.cluster_addons` because it isn't something a caller opts in/out of independently; it's the runtime dependency every Pod Identity association needs, so this module treats it as implied.

## Inputs

| Variable | Required | Default | Notes |
|---|---|---|---|
| `cluster_name` | yes | — | |
| `cluster_version` | yes | — | explicit `"<major>.<minor>"`, never `"latest"` |
| `vpc_id` | yes | — | from `modules/network` |
| `private_subnet_ids` | yes | — | ≥2, from `modules/network`; control plane ENIs and all worker nodes live here |
| `public_access_enabled` | no | `false` | flip to `true` only with an explicit `public_access_cidrs` |
| `public_access_cidrs` | no | `[]` | required non-empty when `public_access_enabled=true` — never defaults to `0.0.0.0/0` |
| `system_node_group` | yes | — | object, see below |
| `cluster_addons` | no | all 4 | `vpc-cni`, `coredns`, `kube-proxy`, `aws-ebs-csi-driver` — the only addons this module wires IAM/config for |
| `tags` | no | `{}` | |

`system_node_group` object fields: `instance_types`, `architecture` (required, `"arm64"`\|`"amd64"`), `min_size`, `desired_size`, `max_size`, `capacity_type` (defaults `"ON_DEMAND"`, and is validated to be exactly that — this module forces On-Demand for `system-on-demand`, no Spot), `root_volume_size` (default `20`), `labels`, `taints`. The node group's `dedicated=system:NoSchedule` taint and `workload-class=system`/`node-lifecycle=on-demand`/`kubernetes.io/arch=<arch>` labels (`docs/eks-node-group-design.md` §1) are always applied by this module regardless of what's passed in `labels`/`taints` — they merge in on top, so the pool can't silently drift from the documented scheduling contract.

## Outputs

| Output | Description |
|---|---|
| `cluster_name` | Name of the EKS cluster |
| `cluster_endpoint` | EKS API server endpoint URL |
| `cluster_certificate_authority_data` | Base64-encoded CA cert, for `kubernetes`/`helm` providers or kubeconfig |
| `cluster_version` | Kubernetes version running on the cluster |
| `oidc_provider_arn` | The cluster's OIDC provider ARN — this module's own addons use Pod Identity, not IRSA, but this is kept available for anything that needs IRSA later |
| `node_security_group_id` | Security group shared by all managed node groups |
| `ebs_csi_pod_identity_role_arn` | The EBS CSI driver's Pod Identity IAM role ARN, when `aws-ebs-csi-driver` is enabled |

## Dependencies

`modules/network` (consumes `vpc_id`, `private_subnet_ids` — must be applied first). External: `terraform-aws-modules/eks/aws ~>21.24`, `hashicorp/aws ~>6.0` (see `versions.tf`). Not a dependency of this module, but a consumer of its outputs: `environments/lab`'s `kubernetes_storage_class_v1.gp3` resource (needs a live, reachable cluster — see Not in this module's interface, below, for why that resource lives at the environment level instead of here).

## Not in this module's interface

No Karpenter NodePool fields — adding them is deferred to whichever PR actually implements Karpenter, per the task that produced this module. No `stateful-*` fields. No Jenkins. No StorageClass resource (see Dependencies above — it's an in-cluster Kubernetes object kept at the `environments/lab` level, deliberately, so this AWS-resource module never needs live cluster connectivity just to `plan`).

## Scheduling: making addons tolerate the `system` taint

The cluster's only node group carries `dedicated=system:NoSchedule`. `vpc-cni` (aws-node) and `kube-proxy` ship as DaemonSets with a built-in wildcard toleration — verified against their published manifests, not a live cluster (none is available in this environment) — so they need no override. `coredns` and the EBS CSI **controller** (a Deployment, unlike the CSI **node** DaemonSet which already tolerates everything) do not tolerate custom taints by default; without an explicit override they would sit `Pending` forever on this cluster, since there is nowhere else to schedule. Both get a `configuration_values` override adding a toleration for `dedicated=system:NoSchedule` — and, per [AWS's own documented CoreDNS caveat](https://docs.aws.amazon.com/eks/latest/userguide/managing-coredns.html), the addon's *default* tolerations (`node-role.kubernetes.io/control-plane`, `node-role.kubernetes.io/master`) have to be repeated alongside the custom one, not just added — see `docs/eks-scheduling-standard.md` §4's consistency checklist, which asks for exactly this to be verified.

This has not been confirmed against a running cluster (no AWS account configured here) — verifying it is the first thing to check once this is actually applied (`docs/eks-lab-deployment.md`): `kubectl -n kube-system get pods` should show every pod `Running`, never `Pending` with a `FailedScheduling` taint-toleration event.

## Addon versions

`addon_version` is left unset for every addon (`most_recent = true`, the underlying module's own default) — this environment has no AWS credentials configured, so there's no way to query `aws eks describe-addon-versions` and pin an exact, verified version string right now. **Known limitation:** whoever runs the first real `apply` against an AWS account should verify and consider pinning exact addon versions at that time rather than relying on `most_recent` indefinitely, the same way `data.aws_ami.latest-amazon-linux-image` floating resolution was flagged as a problem in the legacy code (`docs/current-state-assessment.md` §3).

## Control plane logging

All five control plane log types (`api`, `audit`, `authenticator`, `controllerManager`, `scheduler`) are enabled — Lab is exactly where you want full visibility while shaking out a new foundation. CloudWatch Logs retention is left at the underlying module's default (90 days); revisit if Lab's frequent destroy/recreate cycle makes that an unnecessary cost line.

## Security

- Public API endpoint **off by default** (`public_access_enabled=false`); when enabled, `public_access_cidrs` must be explicit and non-empty — no `0.0.0.0/0` default, enforced by a Terraform `validation` block, not just documentation.
- Private worker nodes only — no node group option exists in this module's interface that places nodes in a public subnet.
- Secrets encrypted via a dedicated, module-managed KMS key (see Secrets encryption, below).
- EBS CSI driver: EKS Pod Identity, least-privilege AWS-managed policy only (see IAM section above) — no `AdministratorAccess` anywhere in this module.
- No SSH: no key pair, no SSH security group rule anywhere in this module.
- Worker root volume: `gp3`, 20GiB default, encrypted, `delete_on_termination=true`.
- **Known, documented exception:** tfsec CRITICAL `aws-ec2-no-public-egress-sgr` on the node security group's default broad egress rule (the upstream module's own recommended-rules default) — suppressed with an inline `tfsec:ignore` and a comment explaining why (private nodes need NAT-routed HTTPS egress for image pulls/AWS API calls; this is the standard, widely-published default for this module, not something introduced here; no AWS account exists in this environment to safely test a hand-narrowed ruleset against real node bootstrap traffic).
- Current `tfsec --minimum-severity HIGH` result: 0 findings beyond the one documented exception above (verified 2026-07 as part of Plan-1001 Phase 2 review).

## Secrets encryption

Left at the underlying module's default: a dedicated, module-managed KMS key encrypts the `secrets` resource. No extra configuration needed here.

## Cost

Lab baseline, always-on while the cluster exists: EKS control plane (**$73/month** flat) + 1× `m7g.large` system node (**≈$60/month**) ≈ **$133/month** — see `docs/eks-capacity-plan.md` §4.1 for the source estimate and Plan-1001 Phase 4 (Cost Review) for the full cross-module breakdown including storage and network. Re-verify against current AWS pricing (Infracost/Pricing Calculator) before treating either number as a real budget — neither has been confirmed against live pricing, since no AWS account is available in this environment.

## Destroy Impact

Node group and cluster teardown must happen *after* any Kubernetes-level cleanup (workloads, PVCs) has finished — see `docs/eks-lab-destroy.md` for the full mandatory ordered sequence and why skipping it risks orphaned EBS volumes (the EBS CSI controller needs the cluster to still be reachable to process PV deletions before the cluster itself goes away). This module's own resources (cluster, node group, IAM role/policy attachment) release cleanly once that Kubernetes-level cleanup has completed; the KMS key created by the underlying module for secrets encryption is scheduled for deletion (not immediately destroyed) per that module's own defaults, which is standard AWS practice, not a gap in this module.

## Validation

- `terraform fmt -check -recursive -diff`: clean.
- `tfsec --minimum-severity HIGH`: 0 findings beyond the one documented, justified exception (see Security).
- `tflint --recursive`: clean.
- `terraform validate` under the CI-pinned Terraform 1.15.8: passing, confirmed via GitHub Actions (this dev environment's local Terraform is 1.5.7, below this module's `required_version`, so local `validate` can't run directly).
- **Not validated:** no `apply` has been run anywhere — no AWS credentials exist in this environment. The taint/toleration overrides (Scheduling section above) and addon behavior are believed correct against published documentation but genuinely unverified against a live cluster; this is the single biggest gap between "this passes static analysis" and "this is proven to work."

## Recovery

The cluster itself holds no application data — recovery for the cluster/node-group/addon layer is re-apply from code. **Data that does need recovery consideration lives one layer up**, in any PVCs provisioned via the `gp3` StorageClass (`environments/lab`) — see that StorageClass's own reclaim policy (`Delete` in Lab, meaning no PV/EBS volume survives its PVC being deleted; Lab holds no data worth recovering by design, per `docs/eks-storage-design.md` §2). If a cluster is ever destroyed with live PVCs still attached without following `docs/eks-lab-destroy.md`'s ordered sequence, the underlying EBS volumes may become orphaned (still billing, no longer reachable from any cluster) rather than "recoverable" — the orphan-EBS check in that destroy doc exists specifically to catch this.

## Reuse

The module's interface (Kubernetes version, architecture, instance types, node counts, endpoint access) is fully parametrized — reusing it for `staging` (not yet wired) means a new `module "eks" {...}` call in `environments/staging/main.tf` with that environment's own variable values, no module code change. **Not yet reusable as-is for Production:** Production needs private-only endpoint access with no public option at all (this module still allows toggling `public_access_enabled=true`, which is appropriate for Lab flexibility but would need a stricter environment-level convention — or a module-level lock — before Production use), multi-AZ node distribution guarantees beyond what a single node group provides, and the Karpenter/`stateful-*`/HA work explicitly out of scope for this version (see Plan-1001 Phase 5, HA Review).
