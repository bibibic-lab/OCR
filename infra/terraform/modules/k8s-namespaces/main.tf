resource "kubernetes_namespace" "zone" {
  for_each = { for z in var.zones : z.name => z }

  metadata {
    name = each.value.name
    labels = merge(
      each.value.labels,
      {
        "app.kubernetes.io/managed-by" = "terraform"
        "pod-security.kubernetes.io/enforce" = "restricted"
        "pod-security.kubernetes.io/warn"    = "restricted"
      }
    )
  }
}
