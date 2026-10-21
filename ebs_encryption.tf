// Account-level EBS encryption by default for this install's account and region.
//
// With this set, the EC2 API encrypts every new EBS volume (Karpenter node root
// volumes, EBS CSI PVCs, volumes restored from snapshots, anything created
// later) with the AWS-managed aws/ebs key, and refuses to create an unencrypted
// one. It is a backstop, so no individual volume source has to be remembered.
//
// Forward-only: existing volumes stay as they are; nodes pick it up as Karpenter
// replaces them. This is a per-account, per-region singleton, so it assumes the
// install owns its account. Destroying it sets the account setting back to false.
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}
