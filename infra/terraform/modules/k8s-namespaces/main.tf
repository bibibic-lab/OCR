resource "kubernetes_namespace_v1" "zone" {
  for_each = { for z in var.zones : z.name => z }

  metadata {
    name = each.value.name
    labels = merge(
      each.value.labels,
      {
        "app.kubernetes.io/managed-by"         = "terraform"
        "pod-security.kubernetes.io/enforce"   = each.value.pss_level
        "pod-security.kubernetes.io/warn"      = each.value.pss_level
      }
    )
  }
}
