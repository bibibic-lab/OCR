variable "namespaces" {
  type = list(string)
}

# 1) 모든 네임스페이스: default-deny ingress + egress
resource "kubernetes_network_policy_v1" "default_deny" {
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
resource "kubernetes_network_policy_v1" "allow_dns" {
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
resource "kubernetes_network_policy_v1" "allow_metrics_scrape" {
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

# 4) admin → processing: 명시 허용 (Phase 1에 포트/파드셀렉터로 세분화)
resource "kubernetes_network_policy_v1" "admin_to_processing" {
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

# 5) kube-apiserver egress: 모든 워크로드(operator·webhook·컨트롤러)가
#    kube-system의 apiserver/Service에 도달해야 함. default-deny Egress가
#    이를 차단하므로 전 네임스페이스에 443/6443 egress를 명시 허용.
#    이것이 없으면 cert-manager·ArgoCD·Operator들이 전부 실패한다.
#
#    주의: kube-apiserver는 host network(노드 IP) + ClusterIP Service로 접근.
#    namespace_selector "kube-system" 은 파드 IP만 매칭하므로
#    ClusterIP(10.96.0.1) 직접 호출은 ipBlock 규칙으로 별도 허용.
variable "apiserver_service_cidr" {
  type        = string
  description = "kube-apiserver Service ClusterIP (kubeadm 기본 10.96.0.1)."
  default     = "10.96.0.1/32"
}

resource "kubernetes_network_policy_v1" "allow_apiserver_egress" {
  for_each = toset(var.namespaces)
  metadata {
    name      = "allow-apiserver-egress"
    namespace = each.value
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]

    # 5a) kube-system ns의 apiserver pod (host network) / non-HA edge cases
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
      ports {
        port     = "6443"
        protocol = "TCP"
      }
    }

    # 5b) kube-apiserver Service ClusterIP (default 10.96.0.1)
    egress {
      to {
        ip_block {
          cidr = var.apiserver_service_cidr
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

# 6) Intra-namespace 허용: 동일 네임스페이스 내 pod-to-pod 통신은 허용.
#    CloudNativePG 복제, SeaweedFS volume-filer, OpenSearch node-to-node,
#    OpenBao Raft 등 스테이트풀 컴포넌트 작동에 필수.
resource "kubernetes_network_policy_v1" "allow_intra_namespace" {
  for_each = toset(var.namespaces)
  metadata {
    name      = "allow-intra-namespace"
    namespace = each.value
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
    ingress {
      from {
        pod_selector {}
      }
    }
    egress {
      to {
        pod_selector {}
      }
    }
  }
}
