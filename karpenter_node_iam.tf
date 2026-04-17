data "aws_partition" "current" {}

locals {
  karpenter_node_iam_role_name          = "Karpenter-${local.cluster_name}"
  karpenter_node_iam_role_policy_prefix = "arn:${data.aws_partition.current.partition}:iam::aws:policy"
}

data "aws_iam_policy_document" "karpenter_node_assume_role" {
  statement {
    sid     = "EKSNodeAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

// Manage the Karpenter node role outside the upstream module so we can move the
// existing policy attachments into the root module without detaching the live
// policies from the role during migration.
resource "aws_iam_role" "karpenter_node" {
  name        = local.karpenter_node_iam_role_name
  path        = "/"
  description = null

  assume_role_policy    = data.aws_iam_policy_document.karpenter_node_assume_role.json
  max_session_duration  = null
  permissions_boundary  = null
  force_detach_policies = true
  tags                  = {}
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "${local.karpenter_node_iam_role_policy_prefix}/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "${local.karpenter_node_iam_role_policy_prefix}/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "${local.karpenter_node_iam_role_policy_prefix}/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni_ipv4" {
  count = module.eks.cluster_ip_family == "ipv4" ? 1 : 0

  role       = aws_iam_role.karpenter_node.name
  policy_arn = "${local.karpenter_node_iam_role_policy_prefix}/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni_ipv6" {
  count = module.eks.cluster_ip_family == "ipv6" ? 1 : 0

  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/AmazonEKS_CNI_IPv6_Policy"
}

// Move the existing upstream-managed role and attachment instances into the
// root module before the module is switched to an externally managed role.
moved {
  from = module.karpenter.aws_iam_role.node[0]
  to   = aws_iam_role.karpenter_node
}

moved {
  from = module.karpenter.aws_iam_role_policy_attachment.node["AmazonEKSWorkerNodePolicy"]
  to   = aws_iam_role_policy_attachment.karpenter_node_worker
}

moved {
  from = module.karpenter.aws_iam_role_policy_attachment.node["AmazonEC2ContainerRegistryReadOnly"]
  to   = aws_iam_role_policy_attachment.karpenter_node_ecr
}

moved {
  from = module.karpenter.aws_iam_role_policy_attachment.node_additional["AmazonSSMManagedInstanceCore"]
  to   = aws_iam_role_policy_attachment.karpenter_node_ssm
}

moved {
  from = module.karpenter.aws_iam_role_policy_attachment.node["AmazonEKS_CNI_Policy"]
  to   = aws_iam_role_policy_attachment.karpenter_node_cni_ipv4[0]
}

moved {
  from = module.karpenter.aws_iam_role_policy_attachment.node["AmazonEKS_CNI_IPv6_Policy"]
  to   = aws_iam_role_policy_attachment.karpenter_node_cni_ipv6[0]
}
