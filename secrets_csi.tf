// Secrets Store CSI Driver as an EKS managed addon.
// Enables pods to mount secrets from AWS Secrets Manager as volumes
// via SecretProviderClass resources.
//
// Karpenter nodes are labeled eks.amazonaws.com/compute-type=ec2 (via NodePool
// template). The affinity excludes Fargate nodes where DaemonSet pods would
// stay Pending indefinitely.

resource "aws_eks_addon" "secrets_store_csi" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "aws-secrets-store-csi-driver-provider"
  addon_version = "v2.2.2-eksbuild.1"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    nodeSelector = {
      "eks.amazonaws.com/compute-type" = "ec2"
    }
    "secrets-store-csi-driver" = {
      syncSecret = { enabled = true }
    }
  })

  depends_on = [
    module.eks,
    kubectl_manifest.karpenter_nodepool_default,
  ]
}
