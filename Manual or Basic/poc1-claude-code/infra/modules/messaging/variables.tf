variable "name_prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "iothub_sku" {
  type = object({
    name     = string
    capacity = number
  })
}

variable "signalr_sku" {
  type = object({
    name     = string
    capacity = number
  })
}

variable "signalr_allowed_origins" {
  description = "Origins allowed to negotiate a SignalR connection (the SPA origin)."
  type        = list(string)
  default     = ["*"]
}

variable "device_root_ca_pem" {
  description = "PEM of the CA signing per-device certificates. Null means bootstrap script handles it."
  type        = string
  sensitive   = true
  default     = null
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
