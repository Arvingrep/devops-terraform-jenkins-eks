module "hcp_terraform_iam" {
  source = "../../modules/aws-iam-hcp"

  hcp_workspace_name   = var.hcp_workspace_name
  resource_name_prefix = var.resource_name_prefix
  create_oidc_provider = var.create_oidc_provider

  tags = var.tags
}
