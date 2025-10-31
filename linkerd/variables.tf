variable "nuon_id" {
  type        = string
  description = "The nuon id for this install. Used for naming purposes."
}

variable "region" {
  type        = string
  description = "The region the cluster is in."
}

variable "eks_oidc_provider_arn" {
  type        = string
  description = "The EKS Cluster OIDC Provider ARN"
}

variable "tags" {
  type        = map(any)
  description = "List of custom tags to add to the install resources. Used for taxonomic purposes."
}
