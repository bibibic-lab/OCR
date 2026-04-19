kube_context = "kind-ocr-dev"

zones = [
  # dmz·observability는 baseline (ingress·node-exporter·OpenSearch init 등
  # hostPath/privilege 요구). 나머지는 restricted.
  { name = "dmz", labels = { zone = "dmz", tier = "external" }, pss_level = "baseline" },
  { name = "processing", labels = { zone = "processing", tier = "internal" } },
  { name = "admin", labels = { zone = "admin", tier = "admin" } },
  { name = "observability", labels = { zone = "observability", tier = "platform" }, pss_level = "baseline" },
  { name = "security", labels = { zone = "security", tier = "platform" } },
]
