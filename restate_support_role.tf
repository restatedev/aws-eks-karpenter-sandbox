# Read-only IAM role for Restate support staff.
#
# Assumed by the Nuon runner's maintenance role during ad-hoc support actions.
# Returns temporary STS credentials scoped to AWS-managed ReadOnlyAccess,
# allowing support staff to diagnose infrastructure issues (EC2 console output,
# EKS access entries, IAM role bindings, etc.) without write access to the
# customer's account.

resource "aws_iam_role" "restate_support" {
  name                 = "${var.nuon_id}-RestateSupport"
  max_session_duration = 43200 # 12h

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.maintenance_iam_role_arn
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "restate_support_readonly" {
  role       = aws_iam_role.restate_support.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
