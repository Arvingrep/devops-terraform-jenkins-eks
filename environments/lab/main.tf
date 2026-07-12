locals {
  name_prefix = "${var.project}-${var.environment}"
  # Computed here (not read from module.eks) so modules/network never
  # depends on modules/eks — module.network must come first in the graph
  # since module.eks consumes its vpc_id/subnet_ids outputs.
  eks_cluster_name = "${local.name_prefix}-eks"
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

  # Lets the EKS control plane and any future in-cluster subnet-discovery
  # consumer (AWS Load Balancer Controller, Karpenter — neither installed
  # in this phase) find these subnets, without modules/network needing to
  # know the cluster name itself (Plan-1001 Phase 1 review finding).
  additional_subnet_tags = {
    "kubernetes.io/cluster/${local.eks_cluster_name}" = "shared"
  }
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.eks_cluster_name
  cluster_version    = var.eks_cluster_version
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  public_access_enabled = var.eks_public_access_enabled
  public_access_cidrs   = var.eks_public_access_cidrs

  system_node_group = var.eks_system_node_group
}

# StorageClass lives here, not in modules/eks: it's an in-cluster Kubernetes
# object that only makes sense once the cluster exists and is reachable, so
# keeping it at the environment level avoids coupling the AWS-resource
# module to live cluster connectivity just to plan.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete" # Lab default — see docs/eks-storage-design.md §1-2
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
}

# Further module calls (jenkins) are added here as later Migration Plan
# phases land — see docs/migration-plan.md.
