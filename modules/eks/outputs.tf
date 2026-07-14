output "cluster_name" {
  value       = module.eks.cluster_name
  description = "Name of the EKS cluster."
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "EKS API server endpoint URL."
}

output "cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Base64-encoded cluster CA certificate, for configuring a kubernetes/helm provider or kubeconfig."
}

output "cluster_version" {
  value       = module.eks.cluster_version
  description = "Kubernetes version running on the cluster."
}

output "oidc_provider_arn" {
  value       = module.eks.oidc_provider_arn
  description = "ARN of the cluster's OIDC provider (module default enable_irsa=true creates it even though this PR uses Pod Identity, not IRSA, for its own addon wiring — kept available for anything that still needs IRSA later)."
}

output "node_security_group_id" {
  value       = module.eks.node_security_group_id
  description = "Security group ID shared by all managed node groups."
}

output "ebs_csi_pod_identity_role_arn" {
  value       = local.enable_ebs_csi ? aws_iam_role.ebs_csi[0].arn : null
  description = "IAM role ARN used by the EBS CSI driver via EKS Pod Identity, when aws-ebs-csi-driver is in var.cluster_addons."
}

output "efs_csi_pod_identity_role_arn" {
  value       = local.enable_efs_csi ? aws_iam_role.efs_csi[0].arn : null
  description = "IAM role ARN used by the EFS CSI driver via EKS Pod Identity, when aws-efs-csi-driver is in var.cluster_addons."
}
