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

# Further outputs (jenkins, eks) are added here as later Migration Plan
# phases land — see docs/migration-plan.md.
