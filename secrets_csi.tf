// Secrets Store CSI Driver + AWS provider.
// Enables pods to mount secrets from AWS Secrets Manager as volumes
// via SecretProviderClass resources.

resource "helm_release" "secrets_store_csi" {
  provider = helm.main

  name       = "secrets-store-csi-driver"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  version    = "1.4.7"

  namespace        = "kube-system"
  create_namespace = false

  timeout = 600

  values = [
    yamlencode({
      syncSecret = { enabled = true }
      linux = {
        affinity = {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [{
                matchExpressions = [
                  {
                    key      = "type"
                    operator = "NotIn"
                    values   = ["virtual-kubelet"]
                  },
                  {
                    key      = "eks.amazonaws.com/compute-type"
                    operator = "NotIn"
                    values   = ["fargate"]
                  },
                ]
              }]
            }
          }
        }
      }
    }),
  ]

  depends_on = [
    module.eks,
    resource.aws_security_group_rule.runner_cluster_access,
    kubectl_manifest.karpenter_nodepool_default,
  ]
}

resource "helm_release" "secrets_store_csi_aws_provider" {
  provider = helm.main

  name       = "secrets-store-csi-driver-provider-aws"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  version    = "0.3.11"

  namespace        = "kube-system"
  create_namespace = false

  timeout = 600

  values = [
    yamlencode({
      affinity = {
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [{
              matchExpressions = [
                {
                  key      = "type"
                  operator = "NotIn"
                  values   = ["virtual-kubelet"]
                },
                {
                  key      = "eks.amazonaws.com/compute-type"
                  operator = "NotIn"
                  values   = ["fargate"]
                },
              ]
            }]
          }
        }
      }
    }),
  ]

  depends_on = [
    helm_release.secrets_store_csi,
  ]
}
