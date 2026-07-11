variable "aws_region" {
  type        = string
  description = "AWS region for the production environment."
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Project slug used in resource names and the Project tag, e.g. wcd-platform."
}

variable "environment" {
  type        = string
  description = "Environment name. Must be \"prod\" in this directory."
  default     = "prod"

  validation {
    condition     = var.environment == "prod"
    error_message = "environments/prod must set environment = \"prod\"."
  }
}

variable "owner" {
  type        = string
  description = "Team accountable for this environment's cost, security, and on-call."
}

variable "cost_center" {
  type        = string
  description = "Cost center tag value, e.g. \"production\"."
  default     = "production"
}

# Module-specific variables (network/jenkins/eks CIDRs, node sizing, HA
# options, etc.) are added here once modules land and main.tf calls them
# (see docs/migration-plan.md). Production defaults must never silently
# inherit Lab's cheap/open settings (ADR-0004).
