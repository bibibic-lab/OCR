kube_context = "kind-ocr-dev"

zones = [
  { name = "dmz", labels = { zone = "dmz", tier = "external" } },
  { name = "processing", labels = { zone = "processing", tier = "internal" } },
  { name = "admin", labels = { zone = "admin", tier = "admin" } },
  { name = "observability", labels = { zone = "observability", tier = "platform" } },
  { name = "security", labels = { zone = "security", tier = "platform" } },
]
