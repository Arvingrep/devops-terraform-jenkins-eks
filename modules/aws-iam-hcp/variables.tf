variable "hcp_organization" {
  type        = string
  description = "HCP Terraform organization name. Must match exactly — it's part of the OIDC trust condition, not just a label."
  default     = "operationarvin"
}

variable "hcp_project" {
  type        = string
  description = "HCP Terraform project name (not ID) that owns the workspace. Must match exactly — see hcp_organization."
  default     = "infra-aws"
}

variable "hcp_workspace_name" {
  type        = string
  description = "HCP Terraform workspace name this role trusts. Only this workspace's plan/apply runs can assume the role — no other workspace, in this or any other organization, can."
}

variable "create_oidc_provider" {
  type        = bool
  description = "Whether to create the app.terraform.io IAM OIDC provider. An AWS account can only have one OIDC provider per issuer URL — if one already exists (e.g. from a prior bootstrap attempt, or another team's setup), set this to false and this module will look it up instead of trying to create a duplicate (which AWS would reject)."
  default     = true
}

variable "role_name" {
  type        = string
  description = "Name of the IAM role HCP Terraform assumes for this workspace."
  default     = "terraform-lab-role"
}

variable "resource_name_prefix" {
  type        = string
  description = "Prefix used to scope this role's permissions to only resources this project creates (IAM role/instance-profile ARNs, EKS cluster names) — e.g. \"wcd-platform-lab\", matching environments/lab's own name_prefix local. Prevents this role from managing IAM roles or clusters belonging to unrelated workloads in the same AWS account."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this module creates."
  default     = {}
}
