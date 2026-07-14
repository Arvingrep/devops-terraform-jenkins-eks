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
      "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:DescribeVpcs", "ec2:DescribeVpcAttribute", "ec2:ModifyVpcAttribute",
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
      "ec2:RunInstances",
      # EFS mount target creation (modules/jenkins) manages its own ENI in
      # the target subnet, and ModifyNetworkInterfaceAttribute is needed
      # because the mount target uses a caller-specified security group
      # rather than the subnet/VPC default.
      "ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface", "ec2:ModifyNetworkInterfaceAttribute",
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
      "eks:CreateFargateProfile", "eks:DeleteFargateProfile", "eks:DescribeFargateProfile", "eks:ListFargateProfiles",
    ]
    # EKS resource-level permissions are inconsistent across this action
    # set in AWS's own reference (some support cluster-name-scoped ARNs,
    # several don't) — left account-wide rather than a partial, uneven
    # scoping that would look more restrictive than it actually is.
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["*"]
  }

  # Gap found via a real speculative plan on PR #6 (Plan-1008): the
  # managed node group doesn't pin ami_release_version, so the upstream
  # terraform-aws-modules/eks/aws module looks up the current
  # recommended AMI via AWS's own public SSM parameter namespace
  # (no account ID in the ARN — it's AWS-owned, not ours). Read-only,
  # scoped to that one namespace, not all of SSM.
  statement {
    sid     = "EKSOptimizedAMILookup"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["arn:aws:ssm:*::parameter/aws/service/eks/optimized-ami/*"]
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
    # trust policy or permissions). The trailing "-*" is a name-prefix
    # match, not an open wildcard — tfsec flags any "*" character.
    #
    # "system-eks-node-group-*" is a second, distinct pattern: found via
    # a real apply attempt (Plan: Recover Tainted VPC, node-group role
    # creation AccessDenied). The upstream terraform-aws-modules/eks/aws
    # managed-node-group submodule names its own IAM role from the node
    # group's map key ("system", modules/eks's only current node group)
    # rather than resource_name_prefix, so it needs its own entry here.
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = [
      "arn:aws:iam::*:role/${var.resource_name_prefix}-*",
      "arn:aws:iam::*:instance-profile/${var.resource_name_prefix}-*",
      "arn:aws:iam::*:role/system-eks-node-group-*",
    ]
  }

  statement {
    sid     = "IAMPassRoleScoped"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    # Scoped to this project's own role name-prefix, plus the
    # iam:PassedToService condition below limits which AWS services can
    # ever be handed one of those roles. Also covers the node-group
    # role's distinct naming pattern (see IAMRoleManagementScoped above)
    # — creating the managed node group requires passing that role to
    # eks.amazonaws.com.
    #
    # pods.eks.amazonaws.com added: EKS CreateAddon with a
    # podIdentityAssociations block (aws-ebs-csi-driver's Pod Identity
    # role) calls iam:PassRole with this service principal — different
    # from the node-group service, found via a real apply AccessDenied
    # (run run-hXY6VWY5g6QUPhN5). Read-only of what gets passed where:
    # the role still cannot be used except by the Pod Identity service.
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = [
      "arn:aws:iam::*:role/${var.resource_name_prefix}-*",
      "arn:aws:iam::*:role/system-eks-node-group-*",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      # eks-fargate-pods.amazonaws.com added for modules/jenkins's Fargate
      # execution role (Jenkins agents) — CreateFargateProfile needs
      # iam:PassRole to that service principal, same pattern as the others.
      values = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "ec2.amazonaws.com", "pods.eks.amazonaws.com", "eks-fargate-pods.amazonaws.com"]
    }
  }

  # Gap found via a real speculative plan on PR #6 (Plan-1007): the
  # upstream terraform-aws-modules/eks/aws module's
  # enable_cluster_creator_admin_permissions=true (modules/eks/main.tf)
  # resolves the calling identity through the AWS provider's own
  # aws_iam_session_context data source, which calls iam:GetRole on the
  # *assumed role's own name* to turn the STS session ARN back into an
  # IAM role ARN. That's this role reading its own metadata, not
  # touching any other role — scoped to its own resource address, never
  # a wildcard or a hardcoded ARN.
  statement {
    sid       = "SelfRoleLookup"
    effect    = "Allow"
    actions   = ["iam:GetRole"]
    resources = [aws_iam_role.terraform_lab.arn]
  }

  # Gap found in Plan-1006 review (Task 4): the upstream
  # terraform-aws-modules/eks/aws module creates standalone managed
  # policies (e.g. the cluster encryption policy, when
  # attach_encryption_policy=true, the module default) in addition to
  # the inline role policies already covered by IAMRoleManagementScoped
  # above. Scoped to only policies this project creates.
  statement {
    sid    = "IAMManagedPolicyLifecycleScoped"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy",
      "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
      "iam:TagPolicy", "iam:UntagPolicy", "iam:ListEntitiesForPolicy",
    ]
    # Scoped to this project's own managed-policy name-prefix only.
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["arn:aws:iam::*:policy/${var.resource_name_prefix}-*"]
  }

  # Separate, read-only statement: attaching an AWS-owned managed policy
  # (e.g. AmazonEBSCSIDriverPolicy, via modules/eks's
  # aws_iam_role_policy_attachment.ebs_csi) needs read access to that
  # policy's own ARN, which lives under the AWS account "aws", not the
  # caller's account — resource_name_prefix scoping doesn't apply here.
  statement {
    sid     = "IAMReadAWSManagedPolicies"
    effect  = "Allow"
    actions = ["iam:GetPolicy", "iam:GetPolicyVersion"]
    # Already scoped to AWS's own "aws" pseudo-account specifically —
    # the narrowest possible scope for "read AWS-owned public managed
    # policies," which have no per-project name to further restrict by.
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["arn:aws:iam::aws:policy/*"]
  }

  # Gap found in Plan-1006 review (Task 4): modules/eks leaves
  # enable_irsa at the upstream module's default (true — see
  # modules/eks/README.md "IAM: EKS Pod Identity, not IRSA"), which
  # creates the *cluster's own* OIDC provider (IRSA support for
  # anything that needs it later) — a completely different OIDC
  # provider from the app.terraform.io one above. Scoped to the EKS
  # OIDC issuer hostname pattern, not resource_name_prefix (the
  # provider's own resource path is a domain name, not a role name).
  statement {
    sid    = "EKSClusterOIDCProviderLifecycle"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviders",
      "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
    ]
    # Scoped to the EKS OIDC issuer hostname pattern specifically —
    # about as narrow as this gets, since the provider's own path
    # segment (the issuer ID) is opaque and only known after creation.
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["arn:aws:iam::*:oidc-provider/oidc.eks.*.amazonaws.com/id/*"]
  }

  # Gap found in Plan-1006 review (Task 4): the first time EKS,
  # EKS-managed-node-groups, or Auto Scaling are used in an AWS account,
  # AWS auto-creates the corresponding service-linked role — the
  # identity applying Terraform needs permission to trigger that
  # creation. Scoped by iam:AWSServiceName, not resource_name_prefix
  # (service-linked role paths are AWS-defined, not ours to name).
  statement {
    sid     = "ServiceLinkedRoleCreation"
    effect  = "Allow"
    actions = ["iam:CreateServiceLinkedRole"]
    # Further restricted by the iam:AWSServiceName condition below —
    # the resource pattern alone can't express "only these 3 services,"
    # so the condition is where the real narrowing happens.
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["arn:aws:iam::*:role/aws-service-role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      # backup.amazonaws.com added for modules/jenkins's aws_efs_backup_policy
      # (PutBackupPolicy AccessDenied on iam:CreateServiceLinkedRole — enabling
      # EFS automatic backups auto-creates AWSServiceRoleForBackup on first use,
      # same class of gap as the EKS/AutoScaling ones already here).
      values = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "autoscaling.amazonaws.com", "backup.amazonaws.com"]
    }
  }

  # Gap found via a real apply (Plan: Finish EKS): EKS's own CreateNodegroup
  # call checks whether AWSServiceRoleForAmazonEKSNodegroup already exists
  # before deciding whether to create it — that check is a plain iam:GetRole,
  # which doesn't support the iam:AWSServiceName condition key the statement
  # above relies on (GetRole never emits that context key), so it needs its
  # own statement rather than being folded into ServiceLinkedRoleCreation.
  #
  # resources scoped to "arn:aws:iam::*:role/aws-service-role/*" was tried
  # first and failed on a real retry with the identical error — confirmed
  # via `aws iam get-role` that the role doesn't exist yet in this account,
  # so EKS's existence-check can't resolve the scoped path/ARN before it
  # knows whether the role (and therefore its path) exists. This is a
  # documented AWS behavior for service-linked-role pre-checks, not unique
  # to this setup. Read-only action, no other iam:Get*/List* granted here.
  statement {
    sid     = "ServiceLinkedRoleLookup"
    effect  = "Allow"
    actions = ["iam:GetRole"]
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["*"]
  }

  # Gap found via a real apply (Plan: Complete AWS Lab, Jenkins EFS
  # infra): modules/jenkins creates an EFS filesystem, its backup policy,
  # and mount targets for Jenkins Home — no elasticfilesystem:* actions
  # existed anywhere in this policy before now. EFS doesn't support
  # resource-level ARN scoping for CreateFileSystem/CreateMountTarget
  # (the resource doesn't exist yet at call time), so this follows the
  # same account-wide pattern as EC2Networking/EKS above, not a shortcut.
  statement {
    sid    = "EFSForJenkinsHome"
    effect = "Allow"
    actions = [
      "elasticfilesystem:CreateFileSystem", "elasticfilesystem:DeleteFileSystem",
      "elasticfilesystem:DescribeFileSystems", "elasticfilesystem:UpdateFileSystem",
      "elasticfilesystem:TagResource", "elasticfilesystem:UntagResource", "elasticfilesystem:ListTagsForResource",
      "elasticfilesystem:PutLifecycleConfiguration", "elasticfilesystem:DescribeLifecycleConfiguration",
      "elasticfilesystem:PutBackupPolicy", "elasticfilesystem:DescribeBackupPolicy",
      "elasticfilesystem:CreateMountTarget", "elasticfilesystem:DeleteMountTarget",
      "elasticfilesystem:DescribeMountTargets", "elasticfilesystem:DescribeMountTargetSecurityGroups",
    ]
    # tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["*"]
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
