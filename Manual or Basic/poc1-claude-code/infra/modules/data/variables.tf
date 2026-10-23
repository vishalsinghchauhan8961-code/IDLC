variable "name_prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "key_vault_id" {
  description = "Key Vault that stores the break-glass SQL admin password."
  type        = string
}

variable "entra_admin" {
  description = "Entra ID group that administers the SQL server."
  type = object({
    object_id    = string
    display_name = string
  })
}

variable "sql_admin_login" {
  description = "SQL admin login name. Required by the API even when Entra-only auth is on."
  type        = string
  default     = "sqladmin"
}

variable "azuread_authentication_only" {
  description = "When true, SQL logins/passwords are rejected entirely. Default true; dev may relax it for tooling."
  type        = bool
  default     = true
}

variable "sku_name" {
  type = string
}

variable "max_size_gb" {
  type = number
}

variable "zone_redundant" {
  type    = bool
  default = false
}

variable "pitr_retention_days" {
  description = "Point-in-time-restore window in days."
  type        = number
  default     = 7
}

variable "public_network_access_enabled" {
  type    = bool
  default = true
}

variable "deploy_agent_ip_ranges" {
  description = "Named IP ranges allowed to run migrations (pipeline agents)."
  type = map(object({
    start = string
    end   = string
  }))
  default = {}
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
