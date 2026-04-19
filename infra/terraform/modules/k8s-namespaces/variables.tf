variable "zones" {
  description = "Zones → namespaces. Optional pss_level per zone (default 'restricted')."
  type = list(object({
    name      = string
    labels    = map(string)
    pss_level = optional(string, "restricted")
  }))
  validation {
    condition = alltrue([
      for z in var.zones : contains(["privileged", "baseline", "restricted"], z.pss_level)
    ])
    error_message = "pss_level must be one of: privileged, baseline, restricted."
  }
}
