terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  # Backend intentionally not declared here yet — ADR-0002 (S3+DynamoDB vs.
  # HCP Terraform Cloud workspaces) is still open. See backend.hcl.example
  # and docs/decisions/ADR-0002-terraform-state.md. Until that is decided,
  # `terraform init` in this directory uses the local backend and must not
  # be pointed at any real environment.
}
