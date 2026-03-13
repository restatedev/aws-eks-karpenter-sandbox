# ACK EKS controller — manages PodIdentityAssociation CRDs, which allow
# the Restate operator to bind IAM roles to environment pods via Pod Identity.
# Only installed when the RestateEnvironment role is enabled.

module "ack_eks_irsa" {
  count = var.restate_environment_role_enabled ? 1 : 0

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.nuon_id}-ack-eks-controller"

  oidc_providers = {
    k8s = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["ack-system:ack-eks-controller"]
    }
  }

  inline_policy_statements = [
    {
      effect = "Allow"
      actions = [
        "eks:CreatePodIdentityAssociation",
        "eks:DeletePodIdentityAssociation",
        "eks:DescribePodIdentityAssociation",
        "eks:ListPodIdentityAssociations",
        "eks:UpdatePodIdentityAssociation",
      ]
      resources = ["*"]
    },
    {
      effect    = "Allow"
      actions   = ["iam:PassRole"]
      resources = [aws_iam_role.restate_environment[0].arn]
    },
  ]

  tags = merge(local.tags, {
    "sandbox.nuon.co/module" = "ack_eks"
  })

  depends_on = [module.eks]
}

resource "helm_release" "ack_eks" {
  count = var.restate_environment_role_enabled ? 1 : 0

  provider = helm.main

  name             = "ack-eks-controller"
  namespace        = "ack-system"
  create_namespace = true
  repository       = "oci://public.ecr.aws/aws-controllers-k8s"
  chart            = "eks-chart"
  version          = "1.4.1"
  timeout          = 300

  values = [
    yamlencode({
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = module.ack_eks_irsa[0].iam_role_arn
        }
      }
      aws = {
        region = var.region
      }
    })
  ]

  depends_on = [
    module.eks,
    module.ack_eks_irsa,
    helm_release.karpenter, # ensure nodes exist for scheduling
  ]
}
