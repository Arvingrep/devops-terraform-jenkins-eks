locals {
  az_count           = length(var.availability_zones)
  nat_gateway_count  = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : local.az_count) : 0
  public_subnet_tags = merge({ "kubernetes.io/role/elb" = "1" }, var.additional_subnet_tags)
  private_subnet_tags = merge(
    { "kubernetes.io/role/internal-elb" = "1" },
    var.additional_subnet_tags
  )
}

# Dedicated VPC resources only — no aws_default_security_group /
# aws_default_route_table (docs/target-architecture.md §5): this module
# never touches the VPC's implicit default SG/route table, so it stays
# composable and doesn't fight AWS's implicit defaults.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  # No auto-assigned public IPs: the only thing that lives in these
  # subnets today is the NAT gateway, which gets its public IP from the
  # explicit aws_eip.nat allocation below, not from this subnet setting.
  # Any future resource that genuinely needs a public IP should request
  # one explicitly rather than inherit it by default (tfsec
  # aws-ec2-no-public-ip-subnet).
  map_public_ip_on_launch = false

  tags = merge(local.public_subnet_tags, {
    Name = "${var.name_prefix}-public-${var.availability_zones[count.index]}"
  })
}

resource "aws_subnet" "private" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.private_subnet_tags, {
    Name = "${var.name_prefix}-private-${var.availability_zones[count.index]}"
  })
}

resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_gateway_count
  allocation_id = aws_eip.nat[count.index].id
  # single_nat_gateway=true still needs exactly one public subnet to place
  # the shared NAT in; count.index is always 0 in that case.
  subnet_id = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.name_prefix}-nat-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ (not shared) so future per-AZ routes
# (VPC endpoints, TGW attachments) don't require reshaping this module's
# resource addresses later.
resource "aws_route_table" "private" {
  count  = local.az_count
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-private-rt-${var.availability_zones[count.index]}"
  }
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat_gateway ? local.az_count : 0
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  # single_nat_gateway=true: every private route table points at the one
  # shared NAT gateway (index 0). single_nat_gateway=false: each AZ's
  # private route table points at its own same-AZ NAT gateway.
  nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  count             = var.enable_vpc_flow_logs ? 1 : 0
  name              = "/wcd/${var.name_prefix}/vpc-flow-logs"
  retention_in_days = var.flow_logs_retention_in_days

  tags = {
    Name = "${var.name_prefix}-vpc-flow-logs"
  }
}

data "aws_iam_policy_document" "flow_logs_assume" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  count              = var.enable_vpc_flow_logs ? 1 : 0
  name               = "${var.name_prefix}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json
}

# Least privilege: scoped to exactly this flow log group's ARN, not "*".
data "aws_iam_policy_document" "flow_logs_permissions" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count  = var.enable_vpc_flow_logs ? 1 : 0
  name   = "${var.name_prefix}-vpc-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs_permissions[0].json
}

resource "aws_flow_log" "this" {
  count                = var.enable_vpc_flow_logs ? 1 : 0
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn         = aws_iam_role.flow_logs[0].arn

  tags = {
    Name = "${var.name_prefix}-vpc-flow-log"
  }
}
