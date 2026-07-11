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
