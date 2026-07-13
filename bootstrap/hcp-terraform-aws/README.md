# bootstrap/hcp-terraform-aws

**Status:** implemented, **not yet applied by anyone**. The root module that actually applies `modules/aws-iam-hcp` — see that module's own README first for what it creates and why. This README is only about the *bootstrap process*: who runs it, when, and what to do with its output.

## Why this exists as a separate root, not just "run the module"

`modules/aws-iam-hcp` is a reusable module — it doesn't apply itself, and it can't be applied through `environments/lab`'s normal HCP-Terraform-remote-execution flow (circular: that flow needs the role this creates). This directory is the actual place a human runs `terraform apply`, with their own real AWS credentials, exactly once per AWS account (until Staging/Prod need their own roles later — see `modules/aws-iam-hcp/README.md` "Reuse").

## Prerequisites

- Real AWS credentials with IAM write access (console, `aws-vault`, or equivalent — **not** stored in this repo, **not** passed to any agent).
- Check whether an `app.terraform.io` OIDC provider already exists in the target account: `aws iam list-open-id-connect-providers`. If one does, you'll set `create_oidc_provider=false` below.

## Apply

```bash
cd bootstrap/hcp-terraform-aws
terraform init
terraform plan   # review: should show exactly 1 OIDC provider (or 0, if reusing an existing one),
                  # 1 IAM role, and the IAM statements described in modules/aws-iam-hcp/README.md
terraform apply
```

Defaults match the real, already-configured `devops-terraform-jenkins-eks-lab` workspace (verified against the live HCP Terraform API during Plan-1005/1006, not assumed) — override only if something has changed since:

```bash
terraform plan \
  -var="hcp_workspace_name=devops-terraform-jenkins-eks-lab" \
  -var="resource_name_prefix=wcd-platform-lab" \
  -var="create_oidc_provider=true"   # false if you found an existing provider above
```

## After apply: wire the role into HCP Terraform (the step this root cannot do itself)

```bash
terraform output -raw role_arn
```

Then either:

- **UI:** `devops-terraform-jenkins-eks-lab` workspace → Variables → add environment variable `TFC_AWS_RUN_ROLE_ARN` = the ARN above.
- **API** (same effect, if you'd rather script it):
  ```bash
  curl -s \
    --header "Authorization: Bearer $TFC_TOKEN" \
    --header "Content-Type: application/vnd.api+json" \
    --request POST \
    --data '{"data":{"type":"vars","attributes":{"key":"TFC_AWS_RUN_ROLE_ARN","value":"<role_arn output>","category":"env","sensitive":false}},"relationships":{"workspace":{"data":{"type":"workspaces","id":"ws-jSSdt2tZqnU6sxgM"}}}}' \
    "https://app.terraform.io/api/v2/vars"
  ```
  (Workspace ID `ws-jSSdt2tZqnU6sxgM` is `devops-terraform-jenkins-eks-lab`'s real ID, confirmed via the API during Plan-1005 — re-verify it hasn't changed before reusing this exact command.)

## Then: confirm PR #6's plan actually succeeds

Re-run (or wait for) the speculative plan on `feature/hcp-workspace` (PR #6). It previously failed with `missing required value(s): AWS role ARN` — after the step above, it should get past that and show a real plan (creating `modules/network` + `modules/eks`'s resources, since `environments/lab/main.tf` already calls both). If it instead fails with `AccessDenied` on some specific action, that's `modules/aws-iam-hcp`'s permission policy missing something — add the exact missing action there (a small, reviewable diff), not a broader policy "to be safe."

## State

Local backend, deliberately — see the comment in `versions.tf`. The resulting `terraform.tfstate` is gitignored like every other state file in this repo; keep it somewhere safe (it's the only record of this bootstrap role's Terraform-managed identity). This root is expected to be applied rarely — once per AWS account, plus again whenever Staging/Prod need their own equivalent roles.
