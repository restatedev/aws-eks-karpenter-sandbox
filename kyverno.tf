locals {
  kyverno = {
    namespace  = "kyverno"
    value_file = "${path.module}/values/kyverno/values.yaml"
    default_policies = [
      "${path.module}/values/kyverno/policies/restrict-binding-system-groups.yaml",
      "${path.module}/values/kyverno/policies/restrict-secret-role-verbs.yaml",
      "${path.module}/values/kyverno/policies/mutate-csi-driver-nodeselector.yaml",
    ]
  }
}

// install kyverno
resource "helm_release" "kyverno" {
  provider = helm.main

  namespace        = "kyverno"
  create_namespace = true

  name       = "kyverno"
  repository = "https://kyverno.github.io/kyverno/"
  chart      = "kyverno"
  version    = "3.5.3"

  values = [
    file(local.kyverno.value_file),
  ]

  depends_on = [
    module.eks,
    resource.aws_security_group_rule.runner_cluster_access,
    kubectl_manifest.karpenter_nodepool_default,
    terraform_data.linkerd_policy_crds_discoverable, // Kyverno must start after Linkerd policy CRDs are discoverable
  ]
}

resource "kubectl_manifest" "default_policies" {
  provider = kubectl.main

  for_each  = toset(local.kyverno.default_policies)
  yaml_body = file(each.value)

  depends_on = [
    helm_release.kyverno
  ]
}

locals {
  // Split vendor policies into RBAC resources (ClusterRoles/Bindings) and
  // Kyverno policies (ClusterPolicy). Kyverno's admission webhook validates
  // generate rules at submission time, checking that its SA has permissions
  // for the referenced GVRs. The RBAC resources that grant those permissions
  // must exist before the policies are applied, otherwise the webhook rejects
  // them with "requires permissions list,get for resource ...".
  vendor_policy_files = fileset(var.kyverno_policy_dir, "*.yaml")
  vendor_policy_contents = {
    for f in local.vendor_policy_files : f => file("${var.kyverno_policy_dir}/${f}")
  }
  vendor_rbac_policies = {
    for f, content in local.vendor_policy_contents : f => content
    if can(regex("\\nkind:\\s*Cluster(Role|RoleBinding)", content))
  }
  vendor_kyverno_policies = {
    for f, content in local.vendor_policy_contents : f => content
    if !can(regex("\\nkind:\\s*Cluster(Role|RoleBinding)", content))
  }
}

resource "kubectl_manifest" "vendor_rbac" {
  provider = kubectl.main

  for_each  = local.vendor_rbac_policies
  yaml_body = each.value

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    helm_release.kyverno,
  ]
}

resource "kubectl_manifest" "vendor_policies" {
  provider = kubectl.main

  for_each  = local.vendor_kyverno_policies
  yaml_body = each.value

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    helm_release.kyverno,
    kubectl_manifest.vendor_rbac,
  ]
}
