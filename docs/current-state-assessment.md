# Current State Assessment

**Scope:** full repository as of commit `5f90d72` on `main`, branch `feature/iac-foundation`.
**Method:** every file below was read in full; `tfsec` was run against both Terraform roots; no AWS console assumptions were used.

## 1. Current directory and Terraform file inventory

```
devops-terraform-jenkins-eks/
├── README.md                                          (1 line — single external link, no real docs)
├── .gitignore                                         (2 lines — see §3, has a real bug)
├── part1-jenkins-from-terraform/
│   ├── backend.tf            (7 lines)
│   ├── provider.tf           (3 lines)
│   ├── variables.tf          (20 lines)
│   ├── terraform.tfvars      (5 lines)
│   ├── vpc.tf                (58 lines)
│   ├── server.tf             (31 lines)
│   └── jenkins-server-setup.sh (23 lines)
└── part2-cluster-from-terraform-and-jenkins/
    ├── Jenkinsfile            (30 lines)
    ├── kubernetes/
    │   ├── deployment.yaml    (19 lines)
    │   └── service.yaml       (15 lines)
    └── terraform-for-cluster/
        ├── backend.tf         (8 lines)
        ├── provider.tf        (3 lines)
        ├── variables.tf       (10 lines)
        ├── terraform.tfvars   (3 lines)
        ├── vpc.tf             (27 lines)
        └── eks-cluster.tf     (26 lines)
```

No `modules/`, `environments/`, `bootstrap/`, `policies/`, `tests/`, or `docs/` directories exist prior to this PR. There is exactly one Git branch (`main`) and one commit (`First commit`) prior to this work.

## 2. AWS resources actually created by this code

**part1 (`part1-jenkins-from-terraform`) — one flat root module:**
- `aws_vpc.myjenkins-server-vpc` — single VPC, no flow logs
- `aws_subnet.myjenkins-server-subnet-1` — **one public subnet, single AZ** (no HA)
- `aws_internet_gateway.myjenkins-server-igw`
- `aws_default_route_table.main-rtbl` — mutates the VPC's *default* route table rather than a dedicated one
- `aws_default_security_group.default-sg` — mutates the VPC's *default* SG rather than a dedicated one; opens **22/tcp and 8080/tcp to `0.0.0.0/0`**, egress `-1` to `0.0.0.0/0`
- `data.aws_ami.latest-amazon-linux-image` — floats to whatever AMI is "most recent" at apply time (not pinned)
- `aws_instance.myjenkins-server` — EC2 `t2.small`, public IP, references `key_name = "jenkins-server-key"` which **is not created anywhere in this code** — it must already exist in the target AWS account or `apply` fails. Root volume is default (unencrypted, per tfsec), no IMDSv2 enforcement, no IAM instance profile.

**part2 (`terraform-for-cluster`) — one flat root module using two upstream registry modules:**
- `module.myjenkins-server-vpc` (`terraform-aws-modules/vpc/aws`, **no `version` pinned**) — 3 public + 3 private subnets, 1 NAT gateway, no VPC flow logs
- `module.eks` (`terraform-aws-modules/eks/aws`, pinned `~>19.0`) — EKS cluster `myjenkins-server-eks-cluster`, Kubernetes `1.24`, `cluster_endpoint_public_access = true` with no CIDR restriction (defaults to `0.0.0.0/0`), one managed node group (`t2.small`, 1–3 nodes, on-demand only, no capacity_type/Spot option), no control-plane logging, IRSA/OIDC not explicitly enabled

**Kubernetes-level:** a plain `nginx` `Deployment` + `LoadBalancer` `Service` (no ingress controller, no TLS) used purely as a manual smoke check.

**Jenkins pipeline (`Jenkinsfile`):** injects long-lived `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` as Jenkins credentials, runs `terraform apply -auto-approve` unconditionally with **no plan-review gate and no destroy stage at all**.

## 3. Current variables and hardcoding

- No `required_version` and no `required_providers` block anywhere (4 provider.tf-equivalents, 0 version pins) — Terraform core and AWS provider versions are fully unconstrained. Local CLI here is `1.5.7`; the newly-connected HCP Terraform workspace defaults to `1.15.8` — these will already disagree on first real run.
- Terraform state backend bucket `mubin-devops-cicd-terraform-eks` is **hardcoded** in both `backend.tf` files and is almost certainly the original tutorial author's personal bucket, not one owned by this AWS account/org — `terraform init` will likely fail until this is replaced (see §6).
- `key_name = "jenkins-server-key"` (part1/server.tf:17) — hardcoded reference to an out-of-band, manually created key pair.
- Region `us-east-1` hardcoded in both `provider.tf` files (not fatal, but not parameterized).
- `.gitignore` contains `.terraform*`, which (in addition to `.terraform/`) also matches and excludes `.terraform.lock.hcl` — the one file that *should* be committed for reproducible provider versions. Currently no lock file exists in the repo at all.
- No `.terraform.lock.hcl` committed for either root — re-running `terraform init` today can silently resolve different provider/module versions than whatever was last applied.
- `terraform-aws-modules/vpc/aws` module source in part2 has **no version constraint** — every fresh `init` can pull a different module version; only `module.eks` is pinned.
- No resource in either root carries any of the standard tags (`Project`, `Environment`, `ManagedBy`, `Owner`, `CostCenter`) — only ad hoc `Name`/`environment`/`application` tags exist.

## 4. Current IAM risk

- The Jenkins EC2 instance has **no IAM instance profile at all** — not over-privileged, but also means there's no path to replace long-lived Jenkins pipeline AWS keys with instance-role-based auth later without a redesign.
- Jenkins pipeline credentials (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) are long-lived IAM user keys stored in Jenkins, not OIDC/STS-based — and Jenkins itself is reachable from the public internet on 8080 (see §5), so compromise of Jenkins directly exposes these keys.
- No IAM roles are defined by Terraform for EKS cluster/node access beyond what the `terraform-aws-modules/eks` module creates implicitly; no IRSA/OIDC provider is enabled, so pod-level least-privilege AWS access isn't possible yet.
- No scoped Terraform bootstrap role exists; whoever runs `terraform apply` today needs broad standing AWS credentials.

## 5. Current network risk (confirmed by `tfsec`, not just inspection)

`tfsec` against `part1-jenkins-from-terraform`:

| Severity | Finding | Location |
|---|---|---|
| HIGH | EC2 instance does not require IMDSv2 token | `server.tf:14-26` |
| HIGH | Root EBS volume not encrypted | `server.tf:14-26` |
| MEDIUM | VPC Flow Logs not enabled | `vpc.tf:1-6` |

`tfsec` against `terraform-for-cluster` (module content included, 785 blocks / 27 files scanned):

| Severity | Finding | Location |
|---|---|---|
| CRITICAL | EKS public cluster endpoint access enabled | `eks-cluster.tf` → `module.eks` |
| CRITICAL | EKS cluster allows access from `0.0.0.0/0` | `eks-cluster.tf` → `module.eks` |
| CRITICAL | Node-group security group egress open to multiple public addresses | `eks-cluster.tf` → `module.eks` |
| CRITICAL ×5 | Default NACL rules from the VPC module allow all ports / public ingress | `vpc.tf` → `module.myjenkins-server-vpc` (module defaults, not something this repo's code sets directly) |
| MEDIUM ×2 | EKS control-plane logging (incl. controller-manager) not enabled | `eks-cluster.tf` → `module.eks` |
| MEDIUM | VPC Flow Logs not enabled | `vpc.tf` → `module.myjenkins-server-vpc` |

Manually confirmed (not flagged by this tfsec ruleset, but explicitly forbidden by the target requirements): `aws_default_security_group.default-sg` opens **SSH 22/tcp and Jenkins 8080/tcp to `0.0.0.0/0`** (`part1-jenkins-from-terraform/vpc.tf:35-58`). This is the single highest-priority fix for the Jenkins module rework.

## 6. Current Terraform State management

- Two independent S3 keys in the **same** bucket (`mubin-devops-cicd-terraform-eks`): `jenkins-server/terraform.tfstate` and `eks/terraform.tfstate`. No environment separation exists at all — there is only ever "the" state, not a lab/staging/prod split.
- **No state locking configured** — neither backend sets `dynamodb_table` (S3 native locking via `use_lockfile` requires Terraform ≥1.10, and no `required_version` pins that anyway). Two concurrent `apply`s today could corrupt state.
- Bucket versioning, encryption, and public-access-block settings cannot be verified from code (no bootstrap module manages this bucket at all) — it was evidently created out-of-band by the tutorial author.
- No backend is parameterized per environment (`backend.hcl` pattern) — the bucket/key are baked directly into `backend.tf`, so copying this repo to a new AWS account requires manually editing two files by hand.
- **New signal this session:** an HCP Terraform Cloud workspace (`operationarvin/infra-aws/devops-terraform-jenkins-eks`) has now been VCS-connected to this repo. Its current settings are `execution-mode = local` and `auto-apply = false`, so connecting it does **not** currently cause GitHub pushes to trigger remote runs — but nothing in the repo's Terraform code points at it yet (no `cloud {}` block or `remote` backend config exists). This is a real alternative to the S3-bootstrap design in the target architecture and is called out as an open decision in `docs/target-architecture.md` / ADR-0002.

## 7. Current Jenkins deployment method

EC2 instance, Amazon Linux 2, provisioned entirely via a single `user_data` bash script (`jenkins-server-setup.sh`) run once at boot:
- Installs Jenkins from the upstream `jenkins.io` yum repo, Java 11, Git, Terraform (via HashiCorp's yum repo — **unpinned, installs whatever is latest at boot time**), and `kubectl` pinned to `v1.23.6` (already several versions behind the EKS `1.24` cluster it targets, and further behind by 2026).
- No EBS data volume for `/var/lib/jenkins` — Jenkins home lives on the root volume; no backup, no snapshot policy.
- No HTTPS/TLS, no reverse proxy/ALB — Jenkins is reached directly on `:8080` over plain HTTP, with the SG open to the entire internet.
- No secrets management — the initial admin password must be retrieved by SSHing into the box (SSH is likewise open to `0.0.0.0/0`).
- Line 2 (`sudo yum update`, no `-y`) is a latent bug: in a non-interactive `user_data` context this will not prompt and effectively no-ops; harmless only because line 6 (`yum upgrade -y`) already does the real update.

## 8. Can the current code `destroy` cleanly?

**Not verified, and likely blocked today**: the hardcoded backend bucket `mubin-devops-cicd-terraform-eks` is not owned by this AWS account/org (no AWS CLI credentials are configured on this machine to confirm directly, but the bucket name pattern strongly suggests the original tutorial author's account). Until the backend is repointed at a bucket this org actually controls, neither `plan` nor `destroy` can run at all — there is currently no reachable state to destroy against. Once repointed to a real bucket: `destroy` would still leave the manually-created `key_name = "jenkins-server-key"` key pair behind (Terraform never created it, so it never deletes it), and — because `aws_default_security_group`/`aws_default_route_table` are *default* resources — a `destroy` resets their rules to blank rather than deleting the objects themselves (not a cost/security problem here since the whole VPC is destroyed with them, but it's a Terraform anti-pattern worth removing when the network module is extracted).

## 8a. Verified: part2 currently fails `terraform validate` outright

This was confirmed by actually running `terraform init -backend=false && terraform validate` against `part2-cluster-from-terraform-and-jenkins/terraform-for-cluster` (via the new `scripts/validate.sh`) — not inferred. With no `required_providers` pin, `init` resolved the newest available `hashicorp/aws` provider, and the downloaded `terraform-aws-modules/eks/aws ~>19.0` module (last updated against an older AWS provider generation) is no longer compatible with it:

```
Error: Unsupported argument
  on .terraform/modules/eks/main.tf line 428, in resource "aws_eks_addon" "before_compute":
    resolve_conflicts = try(each.value.resolve_conflicts, "OVERWRITE")
An argument named "resolve_conflicts" is not expected here.

Error: Unsupported block type
  on .terraform/modules/eks/modules/eks-managed-node-group/main.tf line 104:
    dynamic "elastic_gpu_specifications" { ... }
Blocks of type "elastic_gpu_specifications" are not expected here.
(+3 more of the same shape, incl. "elastic_inference_accelerator")
```

This is not a hypothetical reproducibility risk — it is a live break: `part2` cannot pass `terraform validate` today against a fresh `init`, let alone `plan`/`apply`, until either `eks-cluster.tf` pins `required_providers { aws = { version = "..." } }` to a provider generation the `~>19.0` module actually supports, or the module itself is bumped to a version compatible with the current AWS provider. (`part1` has no such pin either but happens to still `validate` cleanly today — it just has no such guarantee going forward.)

## 9. Can the current code `apply` repeatedly with stable results?

No, for several independent reasons:
- `data.aws_ami.latest-amazon-linux-image` re-resolves "most recent" AMI on every plan — a second `apply` months later can trigger an instance replacement with no code change.
- The unpinned `terraform-aws-modules/vpc/aws` module source can resolve to a different module version between runs.
- No `required_version`/`required_providers` pins mean the AWS provider itself can shift behavior between runs on different machines/CI.
- No `.terraform.lock.hcl` is committed (and the current `.gitignore` would exclude it even if generated).
- Everything is in one flat state per root — there's no environment isolation, so a second `apply` from a different contributor's local `terraform.tfvars` edits can silently clobber another person's lab resources.

## 10. Gap to Production-ready

This is a single-environment tutorial snapshot, not a template. To reach the target described in the WCD requirements it needs, at minimum: a real Terraform state bootstrap this org owns (§6), version pins on Terraform/AWS-provider/all modules (§3), extraction of `network`/`jenkins`/`eks` into reusable modules with variables for NAT/flow-logs/endpoint-access (§8 of the requirements doc), removal of `0.0.0.0/0` on SSH/Jenkins/EKS endpoint, mandatory tagging, per-environment (`lab`/`staging`/`prod`) state and IAM boundaries, OIDC-based CI auth instead of long-lived Jenkins pipeline keys, a destroy workflow (none exists today), and the documentation/ADR set required by §13. None of this requires throwing away the existing resource definitions — they are a reasonable starting point to lift into modules, not a rewrite from scratch.
