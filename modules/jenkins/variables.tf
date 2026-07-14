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

variable "cluster_security_group_id" {
  type        = string
  description = "The EKS cluster's primary security group ID (from modules/eks) — Fargate pods (agents) use this, not node_security_group_id. Needs a DNS ingress rule on the node security group so Fargate agents can resolve in-cluster service names (CoreDNS runs on the node group)."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name (from modules/eks) — the Fargate profile for Jenkins agents attaches to this cluster."
}

variable "fargate_agent_namespace" {
  type        = string
  description = "Kubernetes namespace the Fargate profile selects — only Pods created in this namespace run on Fargate. Jenkins dynamically provisions agent Pods here via the Kubernetes plugin; the controller itself runs on the regular EKS node group, not this namespace."
  default     = "jenkins-agents"
}

variable "tags" {
  type        = map(string)
  description = "Extra tags merged onto every resource this module creates."
  default     = {}
}
