variable "zones" {
  type = list(object({
    name   = string
    labels = map(string)
  }))
}
