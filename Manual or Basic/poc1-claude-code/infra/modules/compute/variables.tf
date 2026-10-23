variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "unique_suffix" {
  description = "Short random suffix for globally-unique names (storage account)."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

# Plan sizing
variable "plan_sku_name" {
  type = string
}

variable "plan_max_elastic_workers" {
  type    = number
  default = 10
}

variable "pre_warmed_instance_count" {
  type    = number
  default = 1
}

variable "storage_replication_type" {
  type    = string
  default = "LRS"
}

# Dependencies
variable "app_insights_connection_string" {
  type      = string
  sensitive = true
}

variable "sql_connection_string" {
  description = "Passwordless (managed identity) SQL connection string."
  type        = string
}

variable "sql_admin_password_secret_id" {
  description = "Key Vault secret id for the break-glass SQL password. Null keeps the runtime completely secret-free."
  type        = string
  default     = null
}

variable "key_vault_id" {
  type = string
}

variable "signalr_id" {
  type = string
}

variable "signalr_hostname" {
  type = string
}

variable "signalr_hub_name" {
  type    = string
  default = "telemetry"
}

variable "iothub_id" {
  type = string
}

variable "iothub_name" {
  type = string
}

variable "iothub_events_fqdn" {
  type = string
}

variable "iothub_events_consumer_group" {
  type = string
}

# Identity (ADR-003). All public identifiers - no client secret exists.
variable "entra_tenant_id" {
  type = string
}

variable "api_app_client_id" {
  type = string
}

variable "spa_app_client_id" {
  type = string
}

# Behaviour
variable "device_offline_after_seconds" {
  type = number
}

variable "reading_retention_days" {
  type = number
}

variable "allowed_cors_origins" {
  type = list(string)
}

variable "alert_email_receivers" {
  description = "Map of receiver name => email address for platform alerts."
  type        = map(string)
  default     = {}
}
