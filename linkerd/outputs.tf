output "all_egress_traffic" {
  value = kubectl_manifest.all_egress_traffic.name
}
