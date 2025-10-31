locals {
  cert_manager = {
    namespace = "cert-manager"
  }
}

resource "helm_release" "linkerd_crds" {
  namespace        = "linkerd"
  create_namespace = true

  name       = "linkerd-crds"
  repository = "https://helm.linkerd.io/edge"
  chart      = "linkerd-crds"
  version    = "2025.8.5"
}

resource "helm_release" "cert_manager_trust" {
  namespace        = local.cert_manager.namespace
  create_namespace = false

  name       = "trust-manager"
  repository = "https://charts.jetstack.io"
  chart      = "trust-manager"
  version    = "v0.20.2"

  values = [yamlencode({
    app = {
      trust = {
        namespace = "linkerd"
      }
    }
    resources = {
      requests = {
        cpu    = "10m",
        memory = "32Mi",
      }
    }
  })]

  depends_on = [helm_release.linkerd_crds] // for the namespace
}


resource "helm_release" "linkerd_control_plane" {
  namespace        = "linkerd"
  create_namespace = false

  name       = "linkerd-control-plane"
  repository = "https://helm.linkerd.io/edge"
  chart      = "linkerd-control-plane"
  version    = "2025.8.5"

  values = [
    yamlencode({
      # Identity Configuration (use cert manager CA)
      identity = {
        issuer = {
          scheme = "kubernetes.io/tls"
        }
        externalCA = true
      }

      # HA Configuration
      # https://github.com/linkerd/linkerd2/blob/main/charts/linkerd-control-plane/values-ha.yaml
      enablePodDisruptionBudget = true
      controller = {
        podDisruptionBudget = {
          maxUnavailable = 1
        }
      }
      deploymentStrategy = {
        rollingUpdate = {
          maxUnavailable = 1
          maxSurge       = "25%"
        }
      }
      enablePodAntiAffinity = true
      proxy = {
        resources = {
          cpu = {
            request = "100m"
          }
          memory = {
            limit   = "250Mi"
            request = "20Mi"
          }
        }
        nativeSidecar = true
      }
      controllerReplicas = 3
      controllerResources = {
        cpu = {
          request = "100m"
        }
        memory = {
          limit   = "250Mi"
          request = "50Mi"
        }
      }
      destinationResources = {
        cpu = {
          request = "100m"
        }
        memory = {
          limit   = "250Mi"
          request = "50Mi"
        }
      }
      identityResources = {
        cpu = {
          request = "100m"
        }
        memory = {
          limit   = "250Mi"
          request = "10Mi"
        }
      }
      heartbeatResources = {
        cpu = {
          request = "100m"
        }
        memory = {
          limit   = "250Mi"
          request = "50Mi"
        }
      }
      proxyInjectorResources = {
        cpu = {
          request = "100m"
        }
        memory = {
          limit   = "250Mi"
          request = "50Mi"
        }
      }
      webhookFailurePolicy = "Fail"
      spValidatorResources = {
        cpu = {
          request = "100m"
        }
        memory = {
          limit   = "250Mi"
          request = "50Mi"
        }
      }
      highAvailability = true
    })
  ]

  depends_on = [
    helm_release.linkerd_crds, // namespace
    kubectl_manifest.linkerd_identity_trust_roots,
    kubectl_manifest.linkerd_identity_issuer
  ]
}

resource "kubectl_manifest" "linkerd_egress_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "linkerd-egress"
    }
  })
}

resource "kubectl_manifest" "all_egress_traffic" {
  yaml_body = yamlencode({
    apiVersion = "policy.linkerd.io/v1alpha1"
    kind       = "EgressNetwork"
    metadata = {
      name      = "all-egress-traffic"
      namespace = "linkerd-egress"
    }
    spec = {
      trafficPolicy = "Allow"
    }
  })

  depends_on = [
    kubectl_manifest.linkerd_egress_namespace,
    helm_release.linkerd_crds,
  ]
}
