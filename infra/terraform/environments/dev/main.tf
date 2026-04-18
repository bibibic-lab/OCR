module "namespaces" {
  source = "../../modules/k8s-namespaces"
  zones  = var.zones
}

module "network_policies" {
  source     = "../../modules/network-policies"
  namespaces = module.namespaces.namespace_names
  depends_on = [module.namespaces]
}

variable "zones" {
  type = list(object({
    name   = string
    labels = map(string)
  }))
}
