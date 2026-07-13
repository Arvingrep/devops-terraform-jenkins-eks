output "role_arn" {
  value       = module.hcp_terraform_iam.role_arn
  description = "Set this exact value as the TFC_AWS_RUN_ROLE_ARN environment variable on the devops-terraform-jenkins-eks-lab HCP Terraform workspace (Workspace -> Variables -> Add variable -> category: env). This is the step this bootstrap root cannot do itself — it has no HCP Terraform API credentials of its own."
}

output "oidc_provider_arn" {
  value       = module.hcp_terraform_iam.oidc_provider_arn
  description = "ARN of the app.terraform.io OIDC provider — either newly created or looked up, depending on create_oidc_provider."
}

output "role_name" {
  value       = module.hcp_terraform_iam.role_name
  description = "Name of the created IAM role, for reference in AWS console/CLI lookups."
}
