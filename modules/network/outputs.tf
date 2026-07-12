output "vpc_id" {
  value       = aws_vpc.this.id
  description = "ID of the created VPC."
}

output "vpc_cidr_block" {
  value       = aws_vpc.this.cidr_block
  description = "CIDR block of the created VPC."
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "IDs of the public subnets, in the same order as availability_zones."
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "IDs of the private subnets, in the same order as availability_zones."
}

output "nat_gateway_ids" {
  value       = aws_nat_gateway.this[*].id
  description = "IDs of the NAT gateway(s). Empty if enable_nat_gateway=false."
}

output "availability_zones" {
  value       = var.availability_zones
  description = "Availability zones this network spans, echoed back for callers that need to align other resources to the same AZ order."
}
