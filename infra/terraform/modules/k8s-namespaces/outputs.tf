output "namespace_names" {
  value = [for ns in kubernetes_namespace.zone : ns.metadata[0].name]
}
