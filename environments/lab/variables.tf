variable "aws_region" {
  type        = string
  description = "AWS region for the lab environment."
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Project slug used in resource names and the Project tag, e.g. wcd-platform."
}

variable "environment" {
  type        = string
  description = "Environment name. Must be \"lab\" in this directory."
  default     = "lab"

  validation {
    condition     = var.environment == "lab"
    error_message = "environments/lab must set environment = \"lab\"."
  }
}

variable "owner" {
  type        = string
  description = "Team or individual accountable for this environment's cost and lifecycle."
}

variable "cost_center" {
  type        = string
  description = "Cost center tag value, e.g. \"lab\"."
  default     = "lab"
}

# --- modules/network ---------------------------------------------------

variable "vpc_cidr_block" {
  type        = string
  description = "CIDR block for the lab VPC."
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones for the lab network. At least 2 (EKS control plane requirement)."
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Public subnet CIDR blocks, one per availability_zones entry."
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDR blocks, one per availability_zones entry."
  default     = ["10.0.16.0/20", "10.0.32.0/20"]
}

variable "enable_vpc_flow_logs" {
  type        = bool
  description = "Whether to enable VPC flow logs for the lab network. Off by default to keep Lab cost minimal."
  default     = false
}

# --- modules/eks ---------------------------------------------------------

variable "eks_cluster_version" {
  type        = string
  description = "Kubernetes <major>.<minor> version for the lab EKS cluster. See modules/eks/README.md for how the current default was chosen and verified."
  default     = "1.35"
}

variable "eks_public_access_enabled" {
  type        = bool
  description = "Whether the lab EKS API endpoint is reachable from outside the VPC. Off by default. Reaching the cluster from outside the VPC (e.g. to run smoke tests from a laptop, since no bastion/VPN exists yet) requires setting this true together with eks_public_access_cidrs — see docs/eks-lab-deployment.md."
  default     = false
}

variable "eks_public_access_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the public API endpoint, when eks_public_access_enabled=true. No default of 0.0.0.0/0 — put your own IP/CIDR in a local (gitignored) terraform.tfvars, never commit a real value here."
  default     = []
}

variable "eks_system_node_group" {
  description = "system-on-demand node group sizing for the lab EKS cluster. Defaults match docs/eks-node-group-design.md §1 and docs/eks-capacity-plan.md §3.3 (Lab: m7g.large, min=1/desired=1/max=2). See modules/eks/README.md for the arm64 rationale."
  type = object({
    instance_types   = list(string)
    architecture     = string
    min_size         = number
    desired_size     = number
    max_size         = number
    capacity_type    = optional(string, "ON_DEMAND")
    root_volume_size = optional(number, 20)
    labels           = optional(map(string), {})
    taints = optional(map(object({
      key    = string
      value  = optional(string)
      effect = string
    })), {})
  })

  default = {
    instance_types = ["m7g.large"]
    architecture   = "arm64"
    min_size       = 1
    desired_size   = 1
    max_size       = 2
  }
}

# Further module-specific variables (jenkins, etc.) are added here as later
# Migration Plan phases land (docs/migration-plan.md).
