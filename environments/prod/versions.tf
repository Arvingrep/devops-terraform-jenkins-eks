terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend intentionally not declared here yet — see ADR-0002. Production
  # must use a state target fully independent from lab/staging (own bucket
  # key or own HCP Terraform workspace) with a restricted IAM role.
}
