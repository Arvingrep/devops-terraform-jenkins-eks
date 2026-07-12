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

# Further module-specific variables (jenkins/eks node sizing, etc.) are
# added here as later Migration Plan phases land (docs/migration-plan.md).
