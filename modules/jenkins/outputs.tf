output "efs_file_system_id" {
  value       = aws_efs_file_system.jenkins_home.id
  description = "EFS filesystem ID for Jenkins Home. Used to statically provision the PersistentVolume from outside Terraform (see modules/jenkins/README.md — the kubernetes-layer objects are applied via kubectl/Helm directly, not through HCP Terraform's remote runners, which can't reach this cluster's private API endpoint)."
}

output "efs_security_group_id" {
  value       = aws_security_group.efs.id
  description = "Security group attached to the EFS mount targets."
}
