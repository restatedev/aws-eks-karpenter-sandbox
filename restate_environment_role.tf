# IAM role assumed by Restate environment pods via EKS Pod Identity.
#
# Grants scoped access to the S3 storage bucket for snapshots, with
# per-environment isolation using session tags (kubernetes-namespace).
# Customers can attach additional policies to this role for their own
# use cases (e.g. Lambda invocation from Restate services).
#
# Mirrors the RestateCloud role in the public Restate Cloud data plane,
# but scoped to a single BYOC install's resources.

resource "aws_iam_role" "restate_environment" {
  count = var.restate_environment_role_enabled ? 1 : 0

  name = "${var.nuon_id}-RestateEnvironment"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
        ]
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "restate_environment_s3" {
  count = var.restate_environment_role_enabled ? 1 : 0

  name = "restate-snapshot-access"
  role = aws_iam_role.restate_environment[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowReadWriteSnapshots"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        # Scope to the environment's prefix within the bucket using the
        # kubernetes-namespace session tag injected by Pod Identity.
        Resource = "${var.restate_environment_storage_bucket_arn}/$${aws:PrincipalTag/kubernetes-namespace}/*"
      },
      {
        Sid    = "AllowListBucketObjects"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = var.restate_environment_storage_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = "$${aws:PrincipalTag/kubernetes-namespace}/*"
          }
        }
      },
    ]
  })
}
