locals {
  ebs_csi = {
    name      = "ebs-csi-controller"
    namespace = "ebs-csi-controller"
  }
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.0"

  role_name             = "ebs-csi-${var.nuon_id}"
  attach_ebs_csi_policy = true

  oidc_providers = {
    k8s = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.ebs_csi.name}:${local.ebs_csi.name}-sa"]
    }
  }

  tags = local.tags
}

// Restoring a volume from a snapshot authorizes ec2:CreateVolume against the
// source snapshot as well as the new volume. The module's managed policy
// (5.0) only covers the volume, through request-tag conditions, so add the
// snapshot side as the upstream aws-ebs-csi-driver example policy does.
resource "aws_iam_role_policy" "ebs_csi_restore_from_snapshot" {
  name = "ebs-csi-restore-from-snapshot"
  role = module.ebs_csi_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateVolume"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:*:*:snapshot/*"
      },
    ]
  })
}

resource "helm_release" "ebs_csi" {
  namespace        = local.ebs_csi.namespace
  create_namespace = true

  name       = local.ebs_csi.name
  repository = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  chart      = "aws-ebs-csi-driver"
  version    = "2.48.0"

  provider = helm.main

  values = [
    yamlencode({
      node : {
        tolerateAllTaints : true
      }
      controller : {
        k8sTagClusterId : module.eks.cluster_name
        serviceAccount : {
          annotations : {
            "eks.amazonaws.com/role-arn" : module.ebs_csi_irsa.iam_role_arn
          }
        }
        tolerations : [
          {
            key : "CriticalAddonsOnly"
            value : "true"
            effect : "NoSchedule"
          },
        ]
      }
      storageClasses : [
        {
          name : "gp3",
          annotations : {
            "storageclass.kubernetes.io/is-default-class" : "true"
          }
          parameters : {
            encrypted : "true",
            "csi.storage.k8s.io/fstype" : "xfs",
            type : "gp3",
          },
          provisioner : "ebs.csi.aws.com",
          reclaimPolicy : "Delete",
          volumeBindingMode : "WaitForFirstConsumer",
          allowVolumeExpansion : true,
        }
      ]
      // Retain keeps the EBS snapshot if the VolumeSnapshot object is deleted,
      // so a snapshot taken to move or restore a volume cannot be lost to a
      // namespace cleanup.
      volumeSnapshotClasses : [
        {
          name : "ebs-retain",
          deletionPolicy : "Retain",
        }
      ]
    }),
  ]


  // The chart adds the csi-snapshotter sidecar and renders volumeSnapshotClasses
  // only when the snapshot.storage.k8s.io CRDs exist, which the
  // snapshot-controller addon installs.
  depends_on = [
    module.ebs_csi_irsa,
    module.eks,
    resource.aws_security_group_rule.runner_cluster_access,
    kubectl_manifest.karpenter_nodepool_default,
    aws_eks_addon.snapshot_controller,
  ]
}

// VolumeSnapshot CRDs and the snapshot controller, so EBS volumes can be
// snapshotted and restored through the Kubernetes API (no AWS credentials in
// the install account needed).
//
// A standalone resource rather than a cluster_addons entry: its pods need a
// Karpenter node, which does not exist yet when the EKS module creates its
// addons. They do not match the kube-system Fargate profile's selectors.
resource "aws_eks_addon" "snapshot_controller" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "snapshot-controller"
  addon_version = "v8.6.0-eksbuild.10"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    module.eks,
    kubectl_manifest.karpenter_nodepool_default,
  ]
}
