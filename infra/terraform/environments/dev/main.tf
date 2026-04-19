# dev 환경은 독립된 Terraform root로 동작.
# root(../../versions.tf, providers.tf, backend.tf)는 참조용이며
# environments/* 각각이 자체 terraform/provider 블록을 갖는다.
terraform {
  required_version = ">= 1.7.0, < 2.0.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25.0, < 4.0.0"
    }
  }
}

variable "kubeconfig_path" {
  type        = string
  description = "kubeconfig path (default: ~/.kube/config)"
  default     = "~/.kube/config"
}

variable "kube_context" {
  type        = string
  description = "kubectl context name to target for this environment."
}

variable "zones" {
  description = "Zones → namespaces. Optional per-zone pss_level (default 'restricted')."
  type = list(object({
    name      = string
    labels    = map(string)
    pss_level = optional(string, "restricted")
  }))
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

module "namespaces" {
  source = "../../modules/k8s-namespaces"
  zones  = var.zones
}

module "network_policies" {
  source     = "../../modules/network-policies"
  namespaces = module.namespaces.namespace_names
  depends_on = [module.namespaces]
}
