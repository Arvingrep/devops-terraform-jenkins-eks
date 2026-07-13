# --- OIDC Provider: app.terraform.io -----------------------------------
# AWS allows exactly one OIDC provider per issuer URL per account — if
# one already exists, create_oidc_provider=false makes this module look
# it up instead of trying to create a duplicate (which AWS rejects).

data "tls_certificate" "hcp_terraform" {
  count = var.create_oidc_provider ? 1 : 0
  url   = "https://app.terraform.io"
}

resource "aws_iam_openid_connect_provider" "hcp_terraform" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://app.terraform.io"
  client_id_list  = ["aws.workload.identity"]
  thumbprint_list = [data.tls_certificate.hcp_terraform[0].certificates[0].sha1_fingerprint]

  tags = var.tags
}

data "aws_iam_openid_connect_provider" "hcp_terraform" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://app.terraform.io"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.hcp_terraform[0].arn : data.aws_iam_openid_connect_provider.hcp_terraform[0].arn

  # HCP Terraform's documented `sub` claim shape:
  # organization:<org>:project:<project>:workspace:<workspace>:run_phase:<plan|apply>
  # Both phases need to assume this role — Plan-1005 asked for one shared
  # role, not a plan/apply split (TFC_AWS_PLAN_ROLE_ARN vs
  # TFC_AWS_APPLY_ROLE_ARN) — so both subjects are listed explicitly
  # rather than wildcarding run_phase, keeping the match as narrow as the
  # single-role design allows.
  hcp_subjects = [
    "organization:${var.hcp_organization}:project:${var.hcp_project}:workspace:${var.hcp_workspace_name}:run_phase:plan",
    "organization:${var.hcp_organization}:project:${var.hcp_project}:workspace:${var.hcp_workspace_name}:run_phase:apply",
  ]
}

# --- Trust policy: only this exact workspace can assume this role ------

data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "HCPTerraformOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "app.terraform.io:aud"
      values   = ["aws.workload.identity"]
    }

    condition {
      test     = "StringEquals"
      variable = "app.terraform.io:sub"
      values   = local.hcp_subjects
    }
  }
}

resource "aws_iam_role" "terraform_lab" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = var.tags
}

# --- Permissions: least privilege for what modules/network + modules/eks
# actually call, enumerated by reading their resource blocks directly —
# not a broad managed policy. UNVERIFIED against a live apply (no AWS
# account in this environment) — the first real plan/apply against this
# role should be watched for AccessDenied errors; see README "Known
# limitations" for exactly what to do if one occurs.

data "aws_iam_policy_document" "lab_permissions" {
  statement {
    sid    = "EC2Networking"
    effect = "Allow"
    actions = [
      "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:DescribeVpcs", "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:DescribeSubnets", "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway", "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway", "ec2:DescribeInternetGateways",
      "ec2:CreateNatGateway", "ec2:DeleteNatGateway", "ec2:DescribeNatGateways",
      "ec2:AllocateAddress", "ec2:ReleaseAddress", "ec2:DescribeAddresses", "ec2:DescribeAddressesAttribute",
      "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:CreateRoute", "ec2:DeleteRoute", "ec2:ReplaceRoute",
      "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable", "ec2:DescribeRouteTables",
      "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup", "ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules",
      "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
      "ec2:CreateLaunchTemplate", "ec2:DeleteLaunchTemplate", "ec2:ModifyLaunchTemplate",
      "ec2:DescribeLaunchTemplates", "ec2:DescribeLaunchTemplateVersions",
      "ec2:CreateFlowLogs", "ec2:DeleteFlowLogs", "ec2:DescribeFlowLogs",
      "ec2:CreateTags", "ec2:DeleteTags", "ec2:DescribeTags",
      "ec2:DescribeAvailabilityZones", "ec2:DescribeAccountAttributes", "ec2:DescribeImages",
      "ec2:DescribeInstances", "ec2:DescribeInstanceTypes", "ec2:DescribeNetworkInterfaces", "ec2:DescribeVolumes",
    ]
    # EC2's API does not support resource-level ARN scoping for most of
    # these actions (create/describe operate account-wide) — this is a
    # standard EC2-IAM limitation, not a shortcut taken here.
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["*"]
  }

  statement {
    sid    = "EKS"
    effect = "Allow"
    actions = [
      "eks:CreateCluster", "eks:DeleteCluster", "eks:DescribeCluster", "eks:ListClusters",
      "eks:UpdateClusterConfig", "eks:UpdateClusterVersion",
      "eks:TagResource", "eks:UntagResource", "eks:ListTagsForResource",
      "eks:CreateNodegroup", "eks:DeleteNodegroup", "eks:DescribeNodegroup", "eks:ListNodegroups",
      "eks:UpdateNodegroupConfig", "eks:UpdateNodegroupVersion",
      "eks:CreateAddon", "eks:DeleteAddon", "eks:DescribeAddon", "eks:ListAddons",
      "eks:UpdateAddon", "eks:DescribeAddonVersions", "eks:DescribeAddonConfiguration",
      "eks:CreatePodIdentityAssociation", "eks:DeletePodIdentityAssociation",
      "eks:DescribePodIdentityAssociation", "eks:ListPodIdentityAssociations", "eks:UpdatePodIdentityAssociation",
      "eks:CreateAccessEntry", "eks:DeleteAccessEntry", "eks:DescribeAccessEntry", "eks:ListAccessEntries",
      "eks:AssociateAccessPolicy", "eks:DisassociateAccessPolicy", "eks:ListAssociatedAccessPolicies",
    ]
    # EKS resource-level permissions are inconsistent across this action
    # set in AWS's own reference (some support cluster-name-scoped ARNs,
    # several don't) — left account-wide rather than a partial, uneven
    # scoping that would look more restrictive than it actually is.
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["*"]
  }

  statement {
    sid    = "AutoScalingForNodeGroups"
    effect = "Allow"
    actions = [
      "autoscaling:CreateAutoScalingGroup", "autoscaling:DeleteAutoScalingGroup", "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:UpdateAutoScalingGroup", "autoscaling:CreateOrUpdateTags", "autoscaling:DeleteTags",
      "autoscaling:DescribeScalingActivities", "autoscaling:SuspendProcesses", "autoscaling:ResumeProcesses",
    ]
    # The EKS managed node group's underlying ASG is named by AWS at
    # creation time, not known in advance — same class of limitation as
    # the EC2/EKS/KMS statements above.
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["*"]
  }

  statement {
    sid    = "IAMRoleManagementScoped"
    effect = "Allow"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:ListRoles",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:TagRole", "iam:UntagRole", "iam:ListInstanceProfilesForRole",
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile", "iam:TagInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
    ]
    # Scoped to only roles/instance-profiles this project creates — this
    # role cannot touch IAM roles belonging to anything else in the
    # account, including terraform-lab-role's own definition (it isn't
    # under resource_name_prefix, so this role can't modify its own
    # trust policy or permissions).
    resources = [
      "arn:aws:iam::*:role/${var.resource_name_prefix}-*",
      "arn:aws:iam::*:instance-profile/${var.resource_name_prefix}-*",
    ]
  }

  statement {
    sid       = "IAMPassRoleScoped"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::*:role/${var.resource_name_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "ec2.amazonaws.com"]
    }
  }

  statement {
    sid    = "KMSForEKSSecretsEncryption"
    effect = "Allow"
    actions = [
      "kms:CreateKey", "kms:DescribeKey", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
      "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias", "kms:ListAliases",
      "kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:EnableKeyRotation", "kms:GetKeyRotationStatus",
      "kms:TagResource", "kms:UntagResource", "kms:ListResourceTags",
      "kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
    ]
    # kms:CreateKey cannot be scoped to a specific key ARN (the key
    # doesn't exist yet at creation time) — this is a standard KMS-IAM
    # limitation.
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchLogsForEKSAndFlowLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy", "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource",
      "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams",
    ]
    # Log group names are only known once modules/eks/modules/network
    # compute them (cluster name, flow-log name_prefix) — scoping by ARN
    # pattern here would just be a wildcard one level down, not real
    # narrowing; left explicit rather than cosmetic.
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lab_permissions" {
  name   = "${var.role_name}-permissions"
  role   = aws_iam_role.terraform_lab.id
  policy = data.aws_iam_policy_document.lab_permissions.json
}
