data "aws_partition" "current" {}

locals {
  karpenter_node_iam_role_name          = "Karpenter-${local.cluster_name}"
  karpenter_node_iam_role_policy_prefix = "arn:${data.aws_partition.current.partition}:iam::aws:policy"

  karpenter_node_policy_arns = sort(concat(
    [
      "${local.karpenter_node_iam_role_policy_prefix}/AmazonEKSWorkerNodePolicy",
      "${local.karpenter_node_iam_role_policy_prefix}/AmazonEC2ContainerRegistryReadOnly",
      "${local.karpenter_node_iam_role_policy_prefix}/AmazonSSMManagedInstanceCore",
    ],
    module.eks.cluster_ip_family == "ipv6" ? [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/AmazonEKS_CNI_IPv6_Policy",
      ] : [
      "${local.karpenter_node_iam_role_policy_prefix}/AmazonEKS_CNI_Policy",
    ],
  ))
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

// Manage the Karpenter node role outside the upstream module so Terraform owns
// a single declarative policy set for the role instead of a set of individually
// replaceable attachments.
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

// Move the existing upstream-managed role and attachment instances into the
// root module before the module is switched to an externally managed role.
moved {
  from = module.karpenter.aws_iam_role.node[0]
  to   = aws_iam_role.karpenter_node
}

resource "aws_iam_role_policy_attachments_exclusive" "karpenter_node" {
  role_name   = aws_iam_role.karpenter_node.name
  policy_arns = local.karpenter_node_policy_arns
}

// Step 1 moved the old upstream attachment instances into these root resources.
// Once every install has crossed that migration, remove those intermediate
// resources from state without detaching the live policies and let the
// exclusive attachment set above take over steady-state ownership.
removed {
  from = aws_iam_role_policy_attachment.karpenter_node_worker

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.karpenter_node_ecr

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.karpenter_node_ssm

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.karpenter_node_cni_ipv4

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.karpenter_node_cni_ipv6

  lifecycle {
    destroy = false
  }
}
