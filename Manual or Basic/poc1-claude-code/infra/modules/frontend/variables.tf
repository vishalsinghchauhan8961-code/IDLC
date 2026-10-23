variable "name_prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  description = "SWA is only available in a subset of regions; keep it separate from the workload region."
  type        = string
}

variable "sku_tier" {
  description = "Free or Standard. Standard is required for a linked backend, custom auth, and an SLA."
  type        = string
  default     = "Standard"
}

variable "api_base_url" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
