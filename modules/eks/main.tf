locals {
  system_ami_type = var.system_node_group.architecture == "arm64" ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"

  # docs/eks-node-group-design.md §1 — these labels/taints are structural,
  # not caller-configurable: they always win over anything passed in via
  # var.system_node_group.labels/taints so the pool can never silently
  # drift from the documented scheduling contract.
  #
  # kubernetes.io/arch is deliberately NOT set here: the EKS
  # CreateNodegroup API rejects any label key under the reserved
  # kubernetes.io/, k8s.io/, or eks.amazonaws.com/ prefixes (found via a
  # real apply — InvalidParameterException). The kubelet sets this label
  # itself on every node based on actual runtime architecture, so it was
  # always redundant, not just invalid to set this way.
  system_required_labels = {
    "workload-class" = "system"
    "node-lifecycle" = "on-demand"
  }
  system_labels = merge(var.system_node_group.labels, local.system_required_labels)

  system_required_taints = {
    dedicated = {
      key    = "dedicated"
      value  = "system"
      effect = "NO_SCHEDULE"
    }
  }
  system_taints = merge(var.system_node_group.taints, local.system_required_taints)

  enable_ebs_csi = contains(var.cluster_addons, "aws-ebs-csi-driver")
  enable_efs_csi = contains(var.cluster_addons, "aws-efs-csi-driver")

  # vpc-cni (aws-node) and kube-proxy ship as DaemonSets with a built-in
  # wildcard toleration (they're designed to run on every node regardless
  # of custom taints) — verified against the addons' published manifests,
  # not a live cluster (none is available in this environment). CoreDNS
  # and the EBS CSI controller are Deployments and do NOT tolerate custom
  # taints by default, so without the overrides below they would sit
  # Pending forever on this cluster's only (tainted) node group. EKS
  # addon config validation requires the *default* tolerations to be
  # repeated alongside any custom one, not just the addition
  # (docs.aws.amazon.com/eks/latest/userguide/managing-coredns.html) —
  # dropping them isn't an option, they have to be included here.
  coredns_tolerations_json = jsonencode({
    tolerations = [
      { key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule" },
      { key = "node-role.kubernetes.io/master", operator = "Exists", effect = "NoSchedule" },
      { key = "dedicated", operator = "Equal", value = "system", effect = "NoSchedule" },
    ]
  })

  ebs_csi_controller_tolerations_json = jsonencode({
    controller = {
      tolerations = [
        { key = "CriticalAddonsOnly", operator = "Exists" },
        { operator = "Exists", effect = "NoExecute", tolerationSeconds = 300 },
        { key = "dedicated", operator = "Equal", value = "system", effect = "NoSchedule" },
      ]
    }
  })

  # Same shape as the EBS CSI controller above — the EFS CSI driver's
  # controller deployment needs the identical toleration override to
  # schedule on this cluster's only (tainted) node group.
  efs_csi_controller_tolerations_json = jsonencode({
    controller = {
      tolerations = [
        { key = "CriticalAddonsOnly", operator = "Exists" },
        { operator = "Exists", effect = "NoExecute", tolerationSeconds = 300 },
        { key = "dedicated", operator = "Equal", value = "system", effect = "NoSchedule" },
      ]
    }
  })

  addon_configuration_values = {
    vpc-cni            = null
    kube-proxy         = null
    coredns            = local.coredns_tolerations_json
    aws-ebs-csi-driver = local.ebs_csi_controller_tolerations_json
    aws-efs-csi-driver = local.efs_csi_controller_tolerations_json
  }

  # EKS Pod Identity Agent isn't in var.cluster_addons because it isn't a
  # workload addon a caller opts in/out of — it's the runtime mechanism
  # every Pod Identity association (below) depends on, so it's implied by
  # enabling any addon that uses pod_identity_association.
  addons = merge(
    { for name in var.cluster_addons : name => {
      before_compute       = name == "vpc-cni"
      most_recent          = true
      configuration_values = local.addon_configuration_values[name]

      pod_identity_association = (
        name == "aws-ebs-csi-driver" && local.enable_ebs_csi
        ) ? [{
          role_arn        = aws_iam_role.ebs_csi[0].arn
          service_account = "ebs-csi-controller-sa"
        }] : (
        name == "aws-efs-csi-driver" && local.enable_efs_csi
        ) ? [{
          role_arn        = aws_iam_role.efs_csi[0].arn
          service_account = "efs-csi-controller-sa"
      }] : null
    } },
    (local.enable_ebs_csi || local.enable_efs_csi) ? {
      "eks-pod-identity-agent" = {
        before_compute = true
        most_recent    = true
      }
    } : {}
  )
}

# tfsec flags this module's own default node security group egress rule
# (0.0.0.0/0, node_groups.tf, node_security_group_enable_recommended_rules)
# as aws-ec2-no-public-egress-sgr CRITICAL. Left as-is deliberately: private
# nodes route outbound through the NAT gateway and need broad HTTPS egress
# to pull container images and reach AWS APIs — this is the standard,
# widely-published default for this module, not something introduced here.
# No AWS account is configured in this environment to safely test a
# hand-narrowed egress ruleset against real node bootstrap traffic, so
# narrowing this is left as a follow-up once there's a real cluster to
# validate against, rather than guessed at blind.
# tfsec:ignore:aws-ec2-no-public-egress-sgr
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  encryption_config = {
    resources = ["secrets"]
  }

  endpoint_private_access      = true
  endpoint_public_access       = var.public_access_enabled
  endpoint_public_access_cidrs = var.public_access_enabled ? var.public_access_cidrs : ["0.0.0.0/0"]

  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # API-only: no aws-auth ConfigMap. Whoever applies this gets admin
  # access automatically so Lab never locks its own creator out.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # create_kms_key stays at the module default (true): a dedicated,
  # module-managed KMS key encrypts the "secrets" resource above.

  addons = local.addons

  eks_managed_node_groups = {
    system = {
      ami_type       = local.system_ami_type
      instance_types = var.system_node_group.instance_types
      capacity_type  = var.system_node_group.capacity_type

      min_size     = var.system_node_group.min_size
      desired_size = var.system_node_group.desired_size
      max_size     = var.system_node_group.max_size

      subnet_ids = var.private_subnet_ids

      labels = local.system_labels
      taints = local.system_taints

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.system_node_group.root_volume_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      tags = var.tags
    }
  }

  tags = var.tags
}

# --- EBS CSI driver: EKS Pod Identity, not IRSA ------------------------
# AWS's current default recommendation for new addon/IAM wiring (see
# modules/eks/README.md). Least privilege: the AWS-managed
# AmazonEBSCSIDriverPolicy, nothing broader.

data "aws_iam_policy_document" "ebs_csi_assume" {
  count = local.enable_ebs_csi ? 1 : 0

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  count              = local.enable_ebs_csi ? 1 : 0
  name               = "${var.cluster_name}-ebs-csi-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count      = local.enable_ebs_csi ? 1 : 0
  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# --- EFS CSI driver: EKS Pod Identity, same pattern as EBS CSI above ---
# Least privilege: the AWS-managed AmazonEFSCSIDriverPolicy, nothing
# broader. Used by modules/jenkins for the persistent Jenkins Home
# filesystem — this module only wires up the driver itself, not any
# specific EFS filesystem.

data "aws_iam_policy_document" "efs_csi_assume" {
  count = local.enable_efs_csi ? 1 : 0

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "efs_csi" {
  count              = local.enable_efs_csi ? 1 : 0
  name               = "${var.cluster_name}-efs-csi-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  count      = local.enable_efs_csi ? 1 : 0
  role       = aws_iam_role.efs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}
