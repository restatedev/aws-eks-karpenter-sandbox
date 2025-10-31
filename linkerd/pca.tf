resource "aws_acmpca_certificate_authority" "linkerd_issuer" {
  type       = "ROOT"
  usage_mode = "SHORT_LIVED_CERTIFICATE"

  certificate_authority_configuration {
    key_algorithm     = "EC_prime256v1"
    signing_algorithm = "SHA256WITHECDSA"

    subject {
      common_name = "root.linkerd.cluster.local"
    }
  }
}

data "aws_partition" "current" {}

resource "aws_acmpca_certificate" "linkerd_issuer" {
  certificate_authority_arn   = aws_acmpca_certificate_authority.linkerd_issuer.arn
  certificate_signing_request = aws_acmpca_certificate_authority.linkerd_issuer.certificate_signing_request
  signing_algorithm           = "SHA256WITHECDSA"

  template_arn = "arn:${data.aws_partition.current.partition}:acm-pca:::template/RootCACertificate/V1"

  validity {
    type  = "YEARS"
    value = 10
  }
}

resource "aws_acmpca_certificate_authority_certificate" "linkerd_issuer" {
  certificate_authority_arn = aws_acmpca_certificate_authority.linkerd_issuer.arn

  certificate       = aws_acmpca_certificate.linkerd_issuer.certificate
  certificate_chain = aws_acmpca_certificate.linkerd_issuer.certificate_chain
}

data "aws_iam_policy_document" "aws_privateca_issuer" {
  statement {
    effect    = "Allow"
    resources = [aws_acmpca_certificate_authority.linkerd_issuer.arn]
    actions = [
      "acm-pca:DescribeCertificateAuthority",
      "acm-pca:GetCertificate",
      "acm-pca:IssueCertificate",
    ]
  }
}

resource "aws_iam_policy" "aws_privateca_issuer" {
  description = "AWS PCA issuer IAM policy"
  name        = "aws-privateca-issuer-${var.nuon_id}"
  policy      = data.aws_iam_policy_document.aws_privateca_issuer.json
}

module "aws_privateca_issuer_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "aws-privateca-issuer-${var.nuon_id}"

  role_policy_arns = {
    policy = aws_iam_policy.aws_privateca_issuer.arn
  }

  oidc_providers = {
    k8s = {
      provider_arn               = var.eks_oidc_provider_arn
      namespace_service_accounts = ["${local.cert_manager.namespace}:aws-privateca-issuer"]
    }
  }

  tags = var.tags
}

resource "helm_release" "aws_privateca_issuer" {
  namespace        = local.cert_manager.namespace
  create_namespace = false

  name       = "aws-privateca-issuer"
  repository = "https://cert-manager.github.io/aws-privateca-issuer"
  chart      = "aws-privateca-issuer"
  version    = "v1.7.0"

  values = [
    yamlencode({
      replicaCount = 1
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = module.aws_privateca_issuer_irsa.iam_role_arn
        }
      }
    })
  ]
}

resource "kubectl_manifest" "linkerd_issuer" {
  yaml_body = yamlencode({
    apiVersion = "awspca.cert-manager.io/v1beta1"
    kind       = "AWSPCAIssuer"
    metadata = {
      name      = "linkerd-issuer"
      namespace = "linkerd"
    }
    spec = {
      arn    = aws_acmpca_certificate_authority.linkerd_issuer.arn,
      region = var.region,
    }
  })

  depends_on = [
    helm_release.aws_privateca_issuer,
    helm_release.linkerd_crds
  ]
}


resource "kubectl_manifest" "linkerd_identity_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "linkerd-identity-issuer"
      namespace = "linkerd"
    }
    spec = {
      isCA       = true
      commonName = "identity.linkerd.cluster.local"
      secretName = "linkerd-identity-issuer"
      // these need to be written out in full or kubernetes_manifest errors
      duration    = "48h0m0s"
      renewBefore = "25h0m0s"
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      issuerRef = {
        group = "awspca.cert-manager.io"
        kind  = "AWSPCAIssuer"
        name  = "linkerd-issuer"
      }
      dnsNames = [
        "identity.linkerd.cluster.local"
      ]
      usages = [
        "cert sign",
        "crl sign",
        "server auth",
        "client auth",
      ]
    }
  })

  depends_on = [
    kubectl_manifest.linkerd_issuer,
    helm_release.linkerd_crds
  ]
}

resource "kubectl_manifest" "linkerd_identity_trust_roots" {
  yaml_body = yamlencode({
    apiVersion = "trust.cert-manager.io/v1alpha1"
    kind       = "Bundle"
    metadata = {
      name = "linkerd-identity-trust-roots"
    }
    spec = {
      sources = [
        {
          secret = {
            name = "linkerd-identity-issuer"
            key  = "ca.crt"
          }
        }
      ]
      target = {
        configMap = {
          key = "ca-bundle.crt"
        }
        namespaceSelector = {
          matchLabels = {
            "kubernetes.io/metadata.name" = "linkerd"
          }
        }
      }
    }
  })

  depends_on = [
    kubectl_manifest.linkerd_identity_issuer,
    helm_release.cert_manager_trust
  ]
}
