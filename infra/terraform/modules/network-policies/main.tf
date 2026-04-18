variable "namespaces" {
  type = list(string)
}

# 1) 모든 네임스페이스: default-deny ingress + egress
resource "kubernetes_network_policy" "default_deny" {
  for_each = toset(var.namespaces)

  metadata {
    name      = "default-deny"
    namespace = each.value
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

# 2) DNS 허용 (모든 네임스페이스 → kube-system/kube-dns)
resource "kubernetes_network_policy" "allow_dns" {
  for_each = toset(var.namespaces)
  metadata {
    name      = "allow-dns"
    namespace = each.value
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }
}

# 3) 관측(observability) → 모든 네임스페이스의 메트릭 포트 수집 허용
resource "kubernetes_network_policy" "allow_metrics_scrape" {
  for_each = toset(var.namespaces)
  metadata {
    name      = "allow-metrics-scrape"
    namespace = each.value
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { zone = "observability" }
        }
      }
      ports {
        port     = "9090"
        protocol = "TCP"
      }
      ports {
        port     = "9100"
        protocol = "TCP"
      }
      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
}

# 4) admin → processing: 명시 허용 (Phase 1에 세분화)
resource "kubernetes_network_policy" "admin_to_processing" {
  metadata {
    name      = "admin-to-processing"
    namespace = "processing"
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = { zone = "admin" }
        }
      }
    }
  }
}
