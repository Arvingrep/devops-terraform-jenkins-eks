variable "aws_region" {
  type        = string
  description = "AWS region to create these (global, but the provider still needs one) IAM resources through."
  default     = "us-east-1"
}

variable "hcp_workspace_name" {
  type        = string
  description = "HCP Terraform workspace this role will trust — must match the real workspace name exactly (organization/project come from modules/aws-iam-hcp's own defaults, operationarvin/infra-aws, matching the real workspace verified via the HCP Terraform API during Plan-1005)."
  default     = "devops-terraform-jenkins-eks-lab"
}

variable "resource_name_prefix" {
  type        = string
  description = "Must match environments/lab's own name_prefix local (project-environment, i.e. \"wcd-platform-lab\" with the tfvars.example defaults) — this is what scopes the created role's own IAM/EKS-OIDC permissions to only resources that environment creates."
  default     = "wcd-platform-lab"
}

variable "create_oidc_provider" {
  type        = bool
  description = "Set to false if an app.terraform.io OIDC provider already exists in this AWS account (check first: aws iam list-open-id-connect-providers). AWS allows only one per issuer URL per account — creating a second one fails."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this bootstrap root creates."
  default = {
    Project     = "wcd-platform"
    Environment = "lab"
    ManagedBy   = "terraform"
    Purpose     = "hcp-terraform-oidc-bootstrap"
  }
}
