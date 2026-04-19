kube_context = "kind-ocr-dev"

zones = [
  # dev 환경의 PSS 완화:
  # - dmz: baseline (ingress proxy 계열)
  # - processing: privileged (SeaweedFS hostPath + OpenBao Raft + CNPG)
  # - observability: baseline (Grafana init, OpenSearch init)
  # - admin, security: restricted 유지
  # Phase 1에 워크로드별 securityContext 엄격화 + 네임스페이스 복원.
  { name = "dmz", labels = { zone = "dmz", tier = "external" }, pss_level = "baseline" },
  { name = "processing", labels = { zone = "processing", tier = "internal" }, pss_level = "privileged" },
  { name = "admin", labels = { zone = "admin", tier = "admin" } },
  { name = "observability", labels = { zone = "observability", tier = "platform" }, pss_level = "baseline" },
  { name = "security", labels = { zone = "security", tier = "platform" } },
]
