# eks module

**Status:** implemented for Migration Plan Phase 4b-1 ("EKS Lab Foundation") only. Wraps `terraform-aws-modules/eks/aws` with a supported Kubernetes version, a single `system-on-demand` managed node group, and a fixed set of core addons. Built against `docs/eks-capacity-plan.md`, `docs/eks-node-group-design.md`, `docs/eks-scheduling-standard.md`, and `docs/eks-storage-design.md` (Phase 4a), which were the gating prerequisite for this module (`docs/migration-plan.md` Phase 4a → 4b).

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

## Interface

| Variable | Required | Notes |
|---|---|---|
| `cluster_name` | yes | |
| `cluster_version` | yes | explicit `"<major>.<minor>"`, never `"latest"` |
| `vpc_id` | yes | from `modules/network` |
| `private_subnet_ids` | yes | ≥2, from `modules/network`; control plane ENIs and all worker nodes live here |
| `public_access_enabled` | no (default `false`) | |
| `public_access_cidrs` | no (default `[]`) | required non-empty when `public_access_enabled=true` — never defaults to `0.0.0.0/0` |
| `system_node_group` | yes | see below |
| `cluster_addons` | no (default all 4) | `vpc-cni`, `coredns`, `kube-proxy`, `aws-ebs-csi-driver` — the only addons this module wires IAM/config for |
| `tags` | no | |

`system_node_group` object fields: `instance_types`, `architecture` (required, `"arm64"`\|`"amd64"`), `min_size`, `desired_size`, `max_size`, `capacity_type` (defaults `"ON_DEMAND"`, and is validated to be exactly that — this module forces On-Demand for `system-on-demand`, no Spot), `root_volume_size` (default `20`), `labels`, `taints`. The node group's `dedicated=system:NoSchedule` taint and `workload-class=system`/`node-lifecycle=on-demand`/`kubernetes.io/arch=<arch>` labels (`docs/eks-node-group-design.md` §1) are always applied by this module regardless of what's passed in `labels`/`taints` — they merge in on top, so the pool can't silently drift from the documented scheduling contract.

## Not in this module's interface

No Karpenter NodePool fields — adding them is deferred to whichever PR actually implements Karpenter, per the task that produced this module. No `stateful-*` fields. No Jenkins.

## Scheduling: making addons tolerate the `system` taint

The cluster's only node group carries `dedicated=system:NoSchedule`. `vpc-cni` (aws-node) and `kube-proxy` ship as DaemonSets with a built-in wildcard toleration — verified against their published manifests, not a live cluster (none is available in this environment) — so they need no override. `coredns` and the EBS CSI **controller** (a Deployment, unlike the CSI **node** DaemonSet which already tolerates everything) do not tolerate custom taints by default; without an explicit override they would sit `Pending` forever on this cluster, since there is nowhere else to schedule. Both get a `configuration_values` override adding a toleration for `dedicated=system:NoSchedule` — and, per [AWS's own documented CoreDNS caveat](https://docs.aws.amazon.com/eks/latest/userguide/managing-coredns.html), the addon's *default* tolerations (`node-role.kubernetes.io/control-plane`, `node-role.kubernetes.io/master`) have to be repeated alongside the custom one, not just added — see `docs/eks-scheduling-standard.md` §4's consistency checklist, which asks for exactly this to be verified.

This has not been confirmed against a running cluster (no AWS account configured here) — verifying it is the first thing to check once this is actually applied (`docs/eks-lab-deployment.md`): `kubectl -n kube-system get pods` should show every pod `Running`, never `Pending` with a `FailedScheduling` taint-toleration event.

## Addon versions

`addon_version` is left unset for every addon (`most_recent = true`, the underlying module's own default) — this environment has no AWS credentials configured, so there's no way to query `aws eks describe-addon-versions` and pin an exact, verified version string right now. **Known limitation:** whoever runs the first real `apply` against an AWS account should verify and consider pinning exact addon versions at that time rather than relying on `most_recent` indefinitely, the same way `data.aws_ami.latest-amazon-linux-image` floating resolution was flagged as a problem in the legacy code (`docs/current-state-assessment.md` §3).

## Control plane logging

All five control plane log types (`api`, `audit`, `authenticator`, `controllerManager`, `scheduler`) are enabled — Lab is exactly where you want full visibility while shaking out a new foundation. CloudWatch Logs retention is left at the underlying module's default (90 days); revisit if Lab's frequent destroy/recreate cycle makes that an unnecessary cost line.

## Secrets encryption

Left at the underlying module's default: a dedicated, module-managed KMS key encrypts the `secrets` resource. No extra configuration needed here.
