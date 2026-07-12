# EKS Lab Destroy

Destroy procedure for the Lab EKS foundation (`docs/migration-plan.md` Phase 4b-1: `modules/network` + `modules/eks` + `environments/lab`). Ordered per `docs/eks-storage-design.md` §6 — do not skip steps or collapse the Kubernetes-level cleanup into a single `terraform destroy`. `reclaimPolicy=Delete` on the `gp3` StorageClass does **not** guarantee no residue: if `terraform destroy` tears down the cluster/node group/VPC before the EBS CSI controller has finished processing PV deletions, the CSI controller has nowhere left to run and the reclaim never completes, leaving an orphaned EBS volume regardless of StorageClass policy.

This procedure does not run automatically — `scripts/infra.sh lab destroy` (Phase 0/1 placeholder today) is where this eventually gets wired up mechanically; until then, run these steps by hand.

## Order

1. **Delete application/StatefulSet workloads** — `kubectl delete` the relevant Deployments/StatefulSets, or delete their namespace(s) outright. (Phase 4b-1 has no real application workloads — only the smoke test's disposable namespace/Pod, which `tests/smoke/eks-lab-smoke-test.sh` already cleans up on its own via its `cleanup` trap. If it didn't run to completion, delete that leftover namespace manually first: `kubectl delete namespace smoke-test --ignore-not-found`.)
2. **Delete PVCs** — triggers the `Delete` reclaim chain (PVC → PV → EBS CSI controller → AWS API `DeleteVolume`) to start.
3. **Wait for PVs and the underlying EBS volumes to actually finish deleting** — poll, don't assume a delete request completing instantly:
   ```bash
   kubectl get pv
   # repeat until none remain that were bound to the namespace(s) removed above
   ```
4. **Run the orphan EBS check** (below) — this is a mandatory step, not optional, even if step 3 reported everything clean.
5. **Delete the node group** — either let `terraform destroy` on `environments/lab` remove `module.eks`'s managed node group, or do it explicitly first if you want to confirm draining behavior before touching the rest of the cluster.
6. **Delete the EKS cluster** — via `terraform destroy` targeting `module.eks`, or the full `environments/lab` destroy.
7. **Delete the network** (`module.network` — VPC/subnets/NAT/IGW) — only after confirming step 4's check is clean. This is the same Terraform state as the cluster in `environments/lab`, so a single `terraform destroy` on the whole environment naturally does this last, correctly, once steps 1–4 are done by hand first.
8. **Report orphan resources** — re-run the full checklist below after the `terraform destroy` completes, not just the EBS-specific check from step 4.

```bash
cd environments/lab
terraform plan -destroy   # review first — see scripts/infra.sh, requirements §10.3
terraform destroy
```

## Orphan EBS check (step 4 — mandatory, not a suggestion)

`docs/eks-storage-design.md` §6: a clean-looking `terraform destroy` does not, by itself, prove there's no leftover EBS volume.

```bash
aws ec2 describe-volumes \
  --filters "Name=status,Values=available" "Name=tag:Project,Values=${TF_VAR_project:-wcd-platform}" "Name=tag:Environment,Values=lab" \
  --query 'Volumes[].{ID:VolumeId,Size:Size,Created:CreateTime}' \
  --output table
```

- Any `gp3` (Delete policy) volume still `available` here means the reclaim chain in step 2–3 did not finish before the cluster/CSI controller went away — do not proceed to delete the network until this is empty or explained.
- Lab: after confirming, it is fine to delete any leftover volume — Lab holds no data worth keeping (`docs/eks-storage-design.md` §2).

## Full orphan resource report (step 8)

Run all of these after `terraform destroy` completes. None of this is automatic yet — there is no CI/CD destroy workflow (`docs/migration-plan.md` Phase 5, not built).

```bash
# EBS volumes left over (same query as step 4, re-run post-destroy)
aws ec2 describe-volumes --filters "Name=status,Values=available" \
  "Name=tag:Project,Values=${TF_VAR_project:-wcd-platform}" "Name=tag:Environment,Values=lab" \
  --query 'Volumes[].VolumeId' --output text

# ENIs left over (a common sign the VPC didn't fully release — e.g. a
# security group or subnet still has an attached interface)
aws ec2 describe-network-interfaces \
  --filters "Name=tag:Project,Values=${TF_VAR_project:-wcd-platform}" "Name=tag:Environment,Values=lab" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status,Description:Description}' --output table

# Security groups left over (should be none once the VPC itself is gone —
# if the VPC delete failed, this is usually why)
aws ec2 describe-security-groups \
  --filters "Name=tag:Project,Values=${TF_VAR_project:-wcd-platform}" "Name=tag:Environment,Values=lab" \
  --query 'SecurityGroups[].{ID:GroupId,Name:GroupName}' --output table

# Load balancers left over (none should exist — this PR installs no
# ingress/LB controller — but check anyway, since a stray one blocks
# subnet/VPC deletion)
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text
aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text

# Elastic IPs left over (the NAT gateway's EIP should release automatically
# with the NAT gateway — confirm it actually did)
aws ec2 describe-addresses \
  --filters "Name=tag:Project,Values=${TF_VAR_project:-wcd-platform}" "Name=tag:Environment,Values=lab" \
  --query 'Addresses[].{IP:PublicIp,AllocationId:AllocationId,AssociationId:AssociationId}' --output table

# NAT Gateway left over (should be gone with modules/network; a NAT stuck
# in "deleting" for a long time is worth a second look, not necessarily a
# bug — deletion is not instant)
aws ec2 describe-nat-gateways \
  --filter "Name=tag:Project,Values=${TF_VAR_project:-wcd-platform}" "Name=tag:Environment,Values=lab" \
  --query 'NatGateways[?State!=`deleted`].{ID:NatGatewayId,State:State}' --output table
```

- **Lab:** if any of the above is non-empty after `terraform destroy`, it's safe to delete by hand — nothing in Lab is meant to outlive the environment (`AutoDestroy=true`).
- Do **not** copy this reasoning to Production: `docs/eks-storage-design.md` §6 §7 is explicit that Prod only ever *reports* residue, never auto-deletes it — a leftover `Retain`-policy volume there may be intentional.

## Known limitations

- None of this is wired into `scripts/infra.sh lab destroy` yet — that script is still the Phase 0/1 placeholder guard rail described in its own comments. This document defines the sequence; a follow-up PR should make `infra.sh destroy` actually execute it instead of only running `terraform destroy`.
- The orphan-resource commands above have not been run against a real account (none is configured in this environment) — they're believed correct against current AWS CLI syntax but unverified end-to-end.
