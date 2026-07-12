variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster."
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes <major>.<minor> version, e.g. \"1.35\". Must be an explicit, currently AWS-supported version — never \"latest\" (see README for how the current default was chosen and verified)."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID to create the cluster and node groups in (from modules/network)."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs (from modules/network) for the control plane ENIs and all worker nodes. Must span at least 2 availability zones (EKS control plane requirement)."

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "private_subnet_ids must contain at least 2 subnets across at least 2 availability zones."
  }
}

variable "public_access_enabled" {
  type        = bool
  description = "Whether the EKS API server endpoint is reachable from outside the VPC. Defaults to false (private-only) — flip to true only with an explicit public_access_cidrs, never a blanket default."
  default     = false
}

variable "public_access_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the public API endpoint. Required (non-empty) when public_access_enabled=true; there is no default of 0.0.0.0/0 — the caller must supply real values, e.g. the operator's own IP/32, once they know it."
  default     = []

  validation {
    condition     = !var.public_access_enabled || length(var.public_access_cidrs) > 0
    error_message = "public_access_cidrs must be explicitly set (non-empty) when public_access_enabled=true. This module never defaults it to 0.0.0.0/0."
  }
}

variable "system_node_group" {
  description = "Configuration for the system-on-demand EKS managed node group (docs/eks-node-group-design.md §1). This PR does not accept a Karpenter NodePool configuration here — Karpenter is out of scope (see README)."
  type = object({
    instance_types   = list(string)
    architecture     = string # "arm64" or "amd64" — must be explicit, no automatic selection.
    min_size         = number
    desired_size     = number
    max_size         = number
    capacity_type    = optional(string, "ON_DEMAND")
    root_volume_size = optional(number, 20)
    labels           = optional(map(string), {})
    taints = optional(map(object({
      key    = string
      value  = optional(string)
      effect = string # AWS API enum: NO_SCHEDULE | NO_EXECUTE | PREFER_NO_SCHEDULE
    })), {})
  })

  validation {
    condition     = var.system_node_group.capacity_type == "ON_DEMAND"
    error_message = "system_node_group.capacity_type must be \"ON_DEMAND\" — docs/eks-node-group-design.md §1 forces On-Demand for system-on-demand; it is never Spot."
  }

  validation {
    condition     = contains(["arm64", "amd64"], var.system_node_group.architecture)
    error_message = "system_node_group.architecture must be exactly \"arm64\" or \"amd64\" — there is no automatic/mixed selection (docs/eks-node-group-design.md §7.1)."
  }
}

variable "cluster_addons" {
  type        = list(string)
  description = "EKS addons to enable. Limited to what this module actually wires up correctly (aws-ebs-csi-driver gets an EKS Pod Identity association; the others don't need one)."
  default     = ["vpc-cni", "coredns", "kube-proxy", "aws-ebs-csi-driver"]

  validation {
    condition = alltrue([
      for a in var.cluster_addons : contains(["vpc-cni", "coredns", "kube-proxy", "aws-ebs-csi-driver"], a)
    ])
    error_message = "cluster_addons may only contain \"vpc-cni\", \"coredns\", \"kube-proxy\", \"aws-ebs-csi-driver\" — this module doesn't wire up IAM/config for any other addon yet."
  }
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged onto every resource this module creates, in addition to whatever the caller's provider default_tags already apply."
  default     = {}
}
