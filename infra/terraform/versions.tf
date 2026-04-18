terraform {
  required_version = ">= 1.7.0, < 2.0.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25.0, < 3.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12.0, < 3.0.0"
    }
    # gavinbunney/kubectl: community provider. Used for server-side
    # apply of raw CRDs/manifests where hashicorp/kubernetes_manifest
    # behavior is insufficient (CRD-before-consumer ordering).
    # Upper-bounded to avoid breakage on a future 2.x.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0, < 2.0.0"
    }
  }
}
