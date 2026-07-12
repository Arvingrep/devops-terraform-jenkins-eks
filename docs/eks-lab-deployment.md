# EKS Lab Deployment

How to actually apply and use the Lab EKS foundation (`docs/migration-plan.md` Phase 4b-1: `modules/network` + `modules/eks` + `environments/lab`). Nothing in this doc has been executed — no AWS credentials are configured in the environment that authored this — so treat the commands below as reviewed-but-unverified until someone with real AWS access runs them.

## Prerequisites

- AWS credentials for the target account, with permissions to create VPCs, EKS clusters/node groups, IAM roles, and KMS keys.
- Terraform pinned per `.terraform-version` (`1.15.8`).
- `kubectl`, `aws` CLI v2 (needed for `aws eks get-token`, used by the `kubernetes` provider and for `kubectl` itself post-apply).
- A backend decision (ADR-0002 is still open) — until that's resolved, `environments/lab` uses the local backend, which is fine for a single operator but not for shared/team use.

## Configure

```bash
cd environments/lab
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
- `project`/`owner` — fill in real values (not the placeholders).
- If you need to reach the cluster API from outside the VPC (no bastion/VPN exists yet, so this is the only way to run `kubectl`/the smoke test from a laptop): uncomment `eks_public_access_enabled = true` and set `eks_public_access_cidrs` to **your own IP/32** — never `0.0.0.0/0` (`modules/eks/README.md`, `docs/current-state-assessment.md` §5).
- Everything else has a working Lab default (`m7g.large`/arm64 system node group, `1.35`, single NAT gateway) — only override if this specific account/region can't satisfy it.

## Apply

```bash
terraform init
terraform plan
terraform apply
```

Not run by this PR (no credentials here, and per the task that produced this module, no agent runs `apply` without a human explicitly asking for that specific run — `docs/migration-plan.md`'s "how to prevent accidental destruction" section). This is what a human (or a future `lab-apply.yml`, once it exists — `docs/migration-plan.md` Phase 5) would run.

## Get kubeconfig

```bash
aws eks update-kubeconfig \
  --name "$(terraform output -raw eks_cluster_name)" \
  --region "$(terraform output -raw aws_region 2>/dev/null || echo us-east-1)"
```

(`aws_region` isn't currently an output — use whatever region you set in `terraform.tfvars` if the command above needs it.) `enable_cluster_creator_admin_permissions=true` in `modules/eks` means whoever ran `apply` already has cluster-admin via an EKS access entry — no extra IAM wiring needed for that first kubeconfig to work.

## Verify

```bash
kubectl get nodes
kubectl -n kube-system get pods
kubectl get storageclass
```

Expect: 1 node (Lab `system-on-demand` default `desired_size=1`), labeled `workload-class=system,node-lifecycle=on-demand,kubernetes.io/arch=arm64` and tainted `dedicated=system:NoSchedule`; `coredns`/`aws-node`/`kube-proxy`/`ebs-csi-*` pods Running in `kube-system`; a `gp3` StorageClass.

Then run the full smoke test:

```bash
./scripts/smoke-test.sh lab
```

See `tests/smoke/README.md` for exactly what it checks.

## Cost while this is running

See `docs/eks-capacity-plan.md` §4.1 — roughly $133/month baseline (EKS control plane + 1× `m7g.large`) if left running continuously; re-verify against current AWS pricing before treating that as a real budget number. Destroy when not actively using it — see `docs/eks-lab-destroy.md` — rather than leaving it up.

## Known limitations

- No CI/CD (`lab-plan.yml`/`lab-apply.yml`) wiring yet — everything above is manual (`docs/migration-plan.md` Phase 5).
- No bastion/VPN — reaching the cluster from outside the VPC requires the public endpoint + your own CIDR, as described above.
- Exact EKS addon versions aren't pinned (`most_recent=true`) — see `modules/eks/README.md` "Addon versions" for why and what to do about it once there's a real account to query.
