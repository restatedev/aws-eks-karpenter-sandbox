// Pre-create the CSI addon namespace with Linkerd webhook exclusion.
// Without this label, Linkerd's fail-closed proxy injector webhook blocks
// pod creation when Linkerd isn't ready, causing the addon to time out.
resource "kubectl_manifest" "secrets_csi_namespace" {
  provider = kubectl.main

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "aws-secrets-manager"
      labels = {
        "config.linkerd.io/admission-webhooks" = "disabled"
      }
    }
  })

  depends_on = [
    module.eks,
    resource.aws_security_group_rule.runner_cluster_access,
  ]
}

// Secrets Store CSI Driver as an EKS managed addon.
// Enables pods to mount secrets from AWS Secrets Manager as volumes
// via SecretProviderClass resources.
//
// Uses nodeSelector to target Karpenter nodes only (karpenter.sh/nodepool=default),
// avoiding Fargate nodes where DaemonSet pods stay Pending indefinitely.
resource "aws_eks_addon" "secrets_store_csi" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "aws-secrets-store-csi-driver-provider"
  addon_version = "v2.2.2-eksbuild.1"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    nodeSelector = {
      "karpenter.sh/nodepool" = "default"
    }
    "secrets-store-csi-driver" = {
      syncSecret = { enabled = true }
      // nodeSelector is not in the sub-chart schema; the Kyverno policy
      // mutate-csi-driver-nodeselector handles node placement for the base driver.
    }
  })

  depends_on = [
    module.eks,
    kubectl_manifest.karpenter_nodepool_default,
    kubectl_manifest.secrets_csi_namespace,
    kubectl_manifest.default_policies, # Kyverno nodeSelector mutation must be ready before addon creates pods
  ]
}

//
// Pod Identity: grant ingress and tunnel pods Secrets Manager read access.
// The SecretProviderClass must set usePodIdentity: "true" for the CSI provider
// to use Pod Identity credentials instead of requiring IRSA annotations.
//

data "aws_iam_policy_document" "secrets_pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

locals {
  // Secrets Manager appends a random suffix to the secret ARN, so scope access
  // to this install's region token by matching the stable name prefix.
  restate_cloud_region_token_secret_arn = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.nuon_id}/restatecloudregiontoken-*"
}

resource "aws_iam_role" "secrets_pod_identity" {
  name               = "secrets-pod-identity-${var.nuon_id}"
  assume_role_policy = data.aws_iam_policy_document.secrets_pod_identity_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "secrets_pod_identity" {
  name = "secrets-manager-read"
  role = aws_iam_role.secrets_pod_identity.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = local.restate_cloud_region_token_secret_arn
    }]
  })
}

resource "aws_eks_pod_identity_association" "ingress" {
  cluster_name    = module.eks.cluster_name
  namespace       = "restate-cloud-ingress"
  service_account = "default"
  role_arn        = aws_iam_role.secrets_pod_identity.arn
  tags            = local.tags
}

resource "aws_eks_pod_identity_association" "tunnel" {
  cluster_name    = module.eks.cluster_name
  namespace       = "restate-cloud-tunnel"
  service_account = "default"
  role_arn        = aws_iam_role.secrets_pod_identity.arn
  tags            = local.tags
}
