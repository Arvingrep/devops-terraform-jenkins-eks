# --- Jenkins Home: EFS, not EBS ----------------------------------------
# Unlike ordinary Lab PVCs (gp3/EBS, reclaimPolicy=Delete — genuinely
# ephemeral by design, see docs/eks-storage-design.md), Jenkins Home must
# survive the Jenkins controller Pod being rescheduled to a different node
# or AZ, and ideally survive a full Lab teardown/rebuild cycle. EBS volumes
# are AZ-bound and single-attach; EFS is regional and can be mounted by a
# freshly recreated cluster. AWS Lab OS v2 §3 covers the full reasoning.

resource "aws_efs_file_system" "jenkins_home" {
  creation_token = "${var.name_prefix}-jenkins-home"
  encrypted      = true

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-jenkins-home"
  })
}

# AWS Backup's built-in daily EFS backup — the actual backup/recovery
# mechanism for Jenkins Home, not just a documentation note.
resource "aws_efs_backup_policy" "jenkins_home" {
  file_system_id = aws_efs_file_system.jenkins_home.id

  backup_policy {
    status = "ENABLED"
  }
}

# One mount target per private subnet/AZ the node group can schedule into,
# so every node has a local, same-AZ NFS mount point.
resource "aws_efs_mount_target" "jenkins_home" {
  for_each = toset(var.private_subnet_ids)

  file_system_id  = aws_efs_file_system.jenkins_home.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# Scoped to exactly the EKS node group's own security group as the only
# allowed source — not a CIDR block, so this can't be reached from
# anything else in the VPC, let alone the internet.
resource "aws_security_group" "efs" {
  name        = "${var.name_prefix}-jenkins-efs"
  description = "Allows NFS (2049) from the EKS node group security group only."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-jenkins-efs"
  })
}

resource "aws_security_group_rule" "efs_ingress_nfs" {
  type                     = "ingress"
  security_group_id        = aws_security_group.efs.id
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = var.node_security_group_id
  description              = "NFS from the EKS node group"
}
