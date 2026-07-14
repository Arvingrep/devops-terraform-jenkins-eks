variable "name_prefix" {
  type        = string
  description = "Prefix applied to every resource's Name tag, matching the convention used by modules/network and modules/eks."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID to create the EFS mount targets and security group in (from modules/network)."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs to place one EFS mount target in each (from modules/network) — must span the same AZs the EKS node group runs in, so every node has a local mount target."
}

variable "node_security_group_id" {
  type        = string
  description = "The EKS node group's shared security group ID (from modules/eks) — the only principal allowed to reach the EFS mount targets on port 2049."
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged onto every resource this module creates."
  default     = {}
}
