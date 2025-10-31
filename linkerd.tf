module "linkerd" {
  providers = {
    kubectl = kubectl.main
    helm    = helm.main
  }

  source = "./linkerd"

  eks_oidc_provider_arn = module.eks.oidc_provider_arn
  region                = var.region
  nuon_id               = var.nuon_id
  tags                  = var.tags

  depends_on = [
    module.eks,
    resource.aws_security_group_rule.runner_cluster_access,
    module.nuon_dns[0].cert_manager,             // Certificate crd
    kubectl_manifest.karpenter_nodepool_default, // so we have nodes to run on
  ]
}
