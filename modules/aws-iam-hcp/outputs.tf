output "role_arn" {
  value       = aws_iam_role.terraform_lab.arn
  description = "ARN of the IAM role HCP Terraform assumes. Set as the HCP Terraform workspace's TFC_AWS_RUN_ROLE_ARN environment variable to complete the OIDC wiring — this module does not set that variable itself (it has no HCP Terraform credentials to do so, and doing it automatically would hide a real cross-system change from human review)."
}

output "oidc_provider_arn" {
  value       = local.oidc_provider_arn
  description = "ARN of the app.terraform.io IAM OIDC provider — either newly created or looked up, depending on create_oidc_provider."
}

output "role_name" {
  value       = aws_iam_role.terraform_lab.name
  description = "Name of the created IAM role, for reference in AWS console/CLI lookups."
}
