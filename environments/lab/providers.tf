provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "devops-terraform-jenkins-eks"
      Owner       = var.owner
      CostCenter  = var.cost_center
      AutoDestroy = "true"
    }
  }
}

# Talks to the lab EKS cluster's API server to manage in-cluster objects
# (StorageClass) that Terraform's aws provider has no resource type for.
# Auth is via `aws eks get-token` (exec plugin) — no static credentials.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}
