# jenkins module

AWS-layer resources for the Lab's Jenkins deployment: persistent controller storage and the Fargate execution path for ephemeral agents. The Kubernetes-layer objects (namespace, PV/PVC, controller Deployment, JCasC config) are **not** in this module — see `environments/lab/k8s/jenkins/README.md` for why and how those are applied.

## What this creates

- **Jenkins Home (EFS, not EBS)**: `aws_efs_file_system` + `aws_efs_access_point` (sets UID/GID 1000 ownership on first mount — required because the Jenkins container runs as UID/GID 1000 and `fsGroup` doesn't apply to EFS/NFS the way it does to EBS) + one `aws_efs_mount_target` per private subnet/AZ. Regional and reattachable, so it survives the controller Pod moving nodes/AZs, unlike an AZ-bound EBS volume.
- **EFS security group**: allows NFS (2049) from the EKS node group's security group only.
- **Fargate agent path**: `aws_eks_fargate_profile` selecting `var.fargate_agent_namespace` (default `jenkins-agents`), with its own pod execution IAM role. Only Pods created in that namespace run on Fargate — the controller itself stays on the regular node group.
- **Fargate → CoreDNS DNS rules**: two `aws_security_group_rule`s (TCP+UDP 53) opening the node security group to the *cluster* security group. Found via a real Fargate agent run that hung on `UnknownHostException` — Fargate pods use the cluster's primary security group, not the node security group, and the node group's existing DNS rules only allowed node-to-node traffic.

## Known issues

- **`aws_efs_backup_policy.jenkins_home` fails to apply.** `PutBackupPolicy` returns `AccessDeniedException` for `iam:CreateServiceLinkedRole` on `backup.amazonaws.com`, even though the grant is present in `modules/aws-iam-hcp` and independently confirmed as `allowed` via `aws iam simulate-principal-policy`. CloudTrail shows the denial with a generic `"An unknown error occurred"` rather than the specific "no identity-based policy allows" message every other real IAM gap in this repo produces — treated as an unresolved AWS-side anomaly, not a policy gap. Non-blocking: Jenkins Home works fully without it; this only affects EFS's own automated daily backup feature. Worth retrying in a fresh apply before assuming it's still broken.

## Why not Terraform for the Kubernetes objects

HCP Terraform's remote runners can't reach this cluster's private-only API endpoint (`endpoint_public_access=false` in `modules/eks`) — confirmed via a real apply attempt (`dial tcp ...: connect: network is unreachable`). See `environments/lab/k8s/jenkins/README.md`.
