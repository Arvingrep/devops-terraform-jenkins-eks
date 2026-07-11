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

# Module-specific variables (network/jenkins/eks CIDRs, node sizing, etc.)
# are added here once modules/network, modules/jenkins, modules/eks land
# and main.tf actually calls them (see docs/migration-plan.md Phase 2-4).
