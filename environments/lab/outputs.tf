output "vpc_id" {
  value       = module.network.vpc_id
  description = "ID of the lab VPC."
}

output "public_subnet_ids" {
  value       = module.network.public_subnet_ids
  description = "Public subnet IDs in the lab VPC."
}

output "private_subnet_ids" {
  value       = module.network.private_subnet_ids
  description = "Private subnet IDs in the lab VPC."
}

output "eks_cluster_name" {
  value       = module.eks.cluster_name
  description = "Name of the lab EKS cluster."
}

output "eks_cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "Lab EKS API server endpoint."
}

output "eks_cluster_version" {
  value       = module.eks.cluster_version
  description = "Kubernetes version running on the lab EKS cluster."
}

# Further outputs (jenkins) are added here as later Migration Plan phases
# land — see docs/migration-plan.md.
