# aws-iam-hcp module

**Status:** implemented, **not yet applied anywhere**. Defines the AWS IAM OIDC provider + role + least-privilege policy that lets HCP Terraform authenticate to AWS for the `devops-terraform-jenkins-eks-lab` workspace, closing the gap found while wiring that workspace (`feature/hcp-workspace`, PR #6): `TFC_AWS_PROVIDER_AUTH=true` was already set, but no `TFC_AWS_RUN_ROLE_ARN` existed for it to use, so every real plan errored with `missing required value(s): AWS role ARN`.

## This is a bootstrap module, not an environment module — read this before applying anything

Unlike `modules/network` or `modules/eks`, this module **cannot** be applied through the normal `environments/lab` → HCP Terraform remote-execution flow. That flow only works *because* the lab workspace can assume an AWS IAM role — which is exactly what this module creates. Applying it through that same workspace would be circular: the workspace needs the role to exist before it can do anything in AWS, including creating the role.

This is the same bootstrap chicken-and-egg problem `docs/decisions/ADR-0002-terraform-state.md` already flagged for the self-managed S3 backend option ("而且存在'鸡生蛋'问题（backend 本身的 backend 要放哪）") — same shape of problem, IAM side instead of state-backend side. It gets the same answer: apply by hand, once, per AWS account, exactly like `bootstrap/backend/` and `bootstrap/github-oidc/` already do. This module lives under `modules/` at the path this Plan specified, but operationally it belongs to that same "one-time, human-run" family — treat it that way regardless of its directory.

## How a human applies this (not run by any agent — no AWS credentials exist in the environment that wrote this)

```bash
cd modules/aws-iam-hcp   # or wherever you choose to call this module from, with real AWS credentials active
terraform init
terraform plan \
  -var="hcp_workspace_name=devops-terraform-jenkins-eks-lab" \
  -var="resource_name_prefix=wcd-platform-lab"
# review the plan — it should show exactly: 1 OIDC provider (or 0 if
# create_oidc_provider=false), 1 IAM role, 1 inline role policy
terraform apply \
  -var="hcp_workspace_name=devops-terraform-jenkins-eks-lab" \
  -var="resource_name_prefix=wcd-platform-lab"
```

Then, using the `role_arn` output:

1. In the HCP Terraform UI, open the `devops-terraform-jenkins-eks-lab` workspace → Variables.
2. Add an environment variable `TFC_AWS_RUN_ROLE_ARN` = the `role_arn` output value.
3. Re-run (or wait for the next VCS-triggered) plan on `feature/hcp-workspace` (PR #6) — it should now get past the `missing required value(s): AWS role ARN` error and produce a real plan (which will show real resources to create, since `environments/lab/main.tf` now calls `modules/network` and `modules/eks`).

**Before running this against a real AWS account:** check whether an OIDC provider for `https://app.terraform.io` already exists (`aws iam list-open-id-connect-providers`) — if it does (e.g. from an earlier attempt, or another team's setup in the same account), set `create_oidc_provider=false` so this module looks it up instead of trying to create a duplicate, which AWS rejects.

## Purpose

Let HCP Terraform assume a scoped AWS IAM role via OIDC (Dynamic Provider Credentials) for exactly one workspace, with no long-lived AWS access keys anywhere.

## Architecture

One `aws_iam_openid_connect_provider` for `https://app.terraform.io` (created, or looked up if one already exists) → one `aws_iam_role` whose trust policy only accepts `sts:AssumeRoleWithWebIdentity` from that OIDC provider, with `StringEquals` conditions on both the audience (`aws.workload.identity`) and the exact `sub` claim for this organization/project/workspace, for both the `plan` and `apply` run phases → one inline `aws_iam_role_policy` scoped to what `modules/network` and `modules/eks` actually call (enumerated by reading their resource blocks directly, not a broad AWS-managed policy).

## Inputs

| Variable | Required | Default | Notes |
|---|---|---|---|
| `hcp_organization` | no | `operationarvin` | Part of the trust condition — must match exactly |
| `hcp_project` | no | `infra-aws` | Same |
| `hcp_workspace_name` | yes | — | The one workspace allowed to assume this role |
| `create_oidc_provider` | no | `true` | Set `false` to reuse an existing `app.terraform.io` provider instead of creating a duplicate |
| `role_name` | no | `terraform-lab-role` | |
| `resource_name_prefix` | yes | — | Scopes the IAM permission set's own IAM-role/instance-profile management to only this project's resources, e.g. `wcd-platform-lab` |
| `tags` | no | `{}` | |

## Outputs

`role_arn`, `oidc_provider_arn`, `role_name` — see `outputs.tf`. None of these are written back to the HCP Terraform workspace automatically; see "How a human applies this" above for why that's a manual step.

## Dependencies

None on other modules in this repository. External: `hashicorp/aws ~>6.0`, `hashicorp/tls ~>4.0` (for the OIDC provider's certificate thumbprint — same pattern `modules/eks`'s own upstream module uses for its cluster OIDC provider).

## Security

- **No `AdministratorAccess`, no wildcard `iam:*` or `*:*`** — every statement in the permissions policy is a specific action list, reasoned from what the actual Terraform modules call.
- IAM role/instance-profile management is scoped to `resource_name_prefix-*` ARNs only — this role cannot modify IAM roles belonging to anything else in the AWS account, including its own definition.
- `iam:PassRole` is further restricted by `iam:PassedToService`, so even within its scoped role ARNs it can only hand them to `eks.amazonaws.com`/`eks-nodegroup.amazonaws.com`/`ec2.amazonaws.com` — not to just any AWS service.
- The trust policy's `sub` condition means **only** the `devops-terraform-jenkins-eks-lab` workspace can ever assume this role — not any other HCP Terraform workspace, in this or any other organization.
- Several statements (EC2, EKS, KMS creation, CloudWatch Logs) are still `resources = ["*"]` — documented inline for each why (EC2/EKS/KMS/Logs APIs don't support resource-level ARN scoping for most create/describe actions at this granularity; this is a platform limitation, not a shortcut).

## Cost

The IAM resources themselves are free (no charge for IAM roles, policies, or OIDC providers). This module's cost impact is entirely indirect — it's what *enables* the real `terraform apply` that would create the billable resources described in Plan-1001's Phase 4 Cost Review (~$170–190/month for the full Lab stack, if left running).

## Destroy Impact

Destroying this role while `environments/lab` still has real applied resources would strand HCP Terraform without a way to plan/apply/destroy them — **always destroy `environments/lab`'s resources first**, then this bootstrap role, never the reverse. The OIDC provider (if this module created it, rather than reusing an existing one) is safe to leave in place even after the role is destroyed — providers are cheap, reusable infrastructure with no ongoing cost, and other roles could trust the same provider later.

## Validation

`terraform fmt -check`, `tflint --recursive`, `tfsec --minimum-severity HIGH`: all clean (verified with Terraform 1.15.8, not just CI). `terraform validate`: **not run** — this module has no caller wiring it up yet (deliberately; see "How a human applies this"), and validating it standalone would require supplying real values for `hcp_workspace_name`/`resource_name_prefix`, which is a one-line `terraform validate` a human can run in seconds once they're ready to actually apply this. **Never applied** — no AWS credentials exist in the environment that wrote this module. The permissions policy is believed correct from reading the actual Terraform resource blocks in `modules/network`/`modules/eks`, but is genuinely unverified against a live apply.

## Recovery

If the role or OIDC provider is accidentally deleted while `environments/lab` has real resources, nothing in AWS itself is affected (IAM changes don't touch EC2/EKS/etc. resources directly) — but HCP Terraform loses its ability to plan/apply/destroy those resources until the role is recreated and `TFC_AWS_RUN_ROLE_ARN` is updated again. Recreating this module's resources (same names, same trust policy) restores access without needing to touch the Lab resources themselves.

## Reuse

Parametrized for one workspace at a time (`hcp_workspace_name`). Reusing for a future Staging or Prod workspace means calling this module again with different `hcp_workspace_name`/`role_name`/`resource_name_prefix` values — `create_oidc_provider=false` on every call after the first, since the OIDC provider is a one-per-account resource shared across all workspace-scoped roles, not created per-environment. The permissions policy would likely need broadening or environment-specific scoping once Staging/Prod introduce resources this policy doesn't yet account for (e.g. `stateful-*` node groups, Jenkins, monitoring) — not attempted here, out of this Plan's scope.

## Known limitations

- Permissions policy is code-reviewed, not apply-tested. First real `terraform plan`/`apply` against this role should be watched closely for `AccessDenied` errors — if one occurs, the fix is to add the specific missing action to the relevant statement in `main.tf` (a small, reviewable diff), not to widen scope broadly "to be safe."
- `Tasks 5 and 6 from this module's originating Plan are not done` — updating `TFC_AWS_RUN_ROLE_ARN` on the real workspace and re-confirming a successful `terraform plan` both require this module to actually be applied first, by a human with real AWS credentials. See "How a human applies this" above.
