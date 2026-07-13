terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local backend, deliberately — no cloud{}/backend block here. This is
  # a one-time, human-run bootstrap root (see README), applied directly
  # with the human's own AWS credentials. It cannot use the
  # devops-terraform-jenkins-eks-lab HCP Terraform workspace's own
  # remote execution: that workspace's ability to reach AWS at all is
  # exactly what this root creates — applying it through that workspace
  # would be circular. Keep the resulting terraform.tfstate somewhere
  # safe (it is gitignored, like every other state file in this repo —
  # never commit it); this root is rarely re-applied, so a durable
  # remote backend for it specifically is more machinery than the
  # problem calls for right now.
}
