variable "name_prefix" {
  description = "Naming prefix, e.g. devtel-dev."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "retention_in_days" {
  description = "Log Analytics retention."
  type        = number
  default     = 30
}

variable "sampling_percentage" {
  description = "Application Insights sampling percentage."
  type        = number
  default     = 100
}

variable "tags" {
  type    = map(string)
  default = {}
}
