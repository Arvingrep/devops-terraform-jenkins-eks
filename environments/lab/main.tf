locals {
  name_prefix = "${var.project}-${var.environment}"
}

module "network" {
  source = "../../modules/network"

  name_prefix          = local.name_prefix
  vpc_cidr_block       = var.vpc_cidr_block
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  enable_nat_gateway   = true
  single_nat_gateway   = true # Lab: cost-optimized, see docs/target-architecture.md §4
  enable_vpc_flow_logs = var.enable_vpc_flow_logs
}

# Further module calls (jenkins, eks) are added here as later Migration
# Plan phases land — see docs/migration-plan.md.
