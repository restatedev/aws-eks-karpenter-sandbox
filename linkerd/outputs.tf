output "all_egress_traffic" {
  value = kubectl_manifest.all_egress_traffic.name
}

// Narrow dependency handle: exposes a release-scoped token for linkerd-crds
// without pulling in the entire module's dependency graph (control plane, PCA,
// etc.). The root module uses this to rerun its active discovery barrier before
// starting Kyverno or applying vendor policies that reference Linkerd GVRs.
output "crds_ready" {
  value = {
    token   = terraform_data.linkerd_crds_release.id
    name    = terraform_data.linkerd_crds_release.output.name
    version = terraform_data.linkerd_crds_release.output.version
  }
}
