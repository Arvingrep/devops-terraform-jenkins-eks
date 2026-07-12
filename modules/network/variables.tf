variable "name_prefix" {
  type        = string
  description = "Prefix applied to every resource's Name tag, e.g. \"wcd-platform-lab\" (see docs/target-architecture.md naming rule)."
}

variable "vpc_cidr_block" {
  type        = string
  description = "CIDR block for the VPC."
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones to spread subnets across. EKS requires at least 2."

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least 2 availability zones are required (Amazon EKS control plane requirement)."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Public subnet CIDR blocks, one per entry in availability_zones, same order."

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.availability_zones)
    error_message = "public_subnet_cidrs must have exactly one entry per availability_zones entry."
  }
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDR blocks, one per entry in availability_zones, same order."

  validation {
    condition     = length(var.private_subnet_cidrs) == length(var.availability_zones)
    error_message = "private_subnet_cidrs must have exactly one entry per availability_zones entry."
  }
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Whether to create NAT gateway(s) and default-route private subnets through them."
  default     = true
}

variable "single_nat_gateway" {
  type        = bool
  description = "If true, create one NAT gateway shared by all private subnets (cost-optimized, used by Lab). If false, one NAT gateway per availability zone."
  default     = false
}

variable "enable_vpc_flow_logs" {
  type        = bool
  description = "Whether to enable VPC flow logs to CloudWatch Logs."
  default     = false
}

variable "flow_logs_retention_in_days" {
  type        = number
  description = "CloudWatch Logs retention for VPC flow logs, when enabled."
  default     = 14
}

variable "additional_subnet_tags" {
  type        = map(string)
  description = "Extra tags merged onto every public and private subnet, e.g. EKS/Karpenter discovery tags (kubernetes.io/cluster/<name>, karpenter.sh/discovery) once a cluster consuming this network exists. Kept generic here so this module doesn't need to know about any specific EKS cluster."
  default     = {}
}
