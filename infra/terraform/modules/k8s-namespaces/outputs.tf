output "namespace_names" {
  value = [for ns in kubernetes_namespace_v1.zone : ns.metadata[0].name]
}
