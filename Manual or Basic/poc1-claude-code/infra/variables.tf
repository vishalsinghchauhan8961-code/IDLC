variable "subscription_id" {
  description = "Target Azure subscription id. Supplied by the pipeline, never committed."
  type        = string
}

variable "environment" {
  description = "Short environment name used in resource naming (dev | test | prod)."
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, prod."
  }
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westeurope"
}

variable "workload" {
  description = "Workload short name; drives resource naming."
  type        = string
  default     = "devtel"

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.workload))
    error_message = "workload must be 3-10 lowercase alphanumeric characters."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Identity / auth (ADR-003)
# ---------------------------------------------------------------------------

variable "entra_tenant_id" {
  description = "Microsoft Entra ID tenant id that issues operator tokens."
  type        = string
}

variable "api_app_client_id" {
  description = "Entra app registration (client) id of the telemetry API. Tokens are validated against this audience."
  type        = string
}

variable "spa_app_client_id" {
  description = "Entra app registration (client) id of the Angular SPA. Used for CORS/allowed-audience wiring and surfaced via GET /config/auth."
  type        = string
}

variable "sql_entra_admin" {
  description = <<-EOT
    Entra ID group that owns the SQL server (object_id + display name). A group, not a
    person, so no human account is a single point of failure. This group is what the
    deployment pipeline uses to create the managed-identity DB users.
  EOT
  type = object({
    object_id    = string
    display_name = string
  })
}

# ---------------------------------------------------------------------------
# Capacity / cost knobs (see ADR-001 trade-offs)
# ---------------------------------------------------------------------------

variable "iothub_sku" {
  description = "IoT Hub SKU and capacity. S1 = 400k msg/day per unit; B/F SKUs are rejected because they lack message routing / cloud-to-device features we need later."
  type = object({
    name     = string
    capacity = number
  })
  default = {
    name     = "S1"
    capacity = 1
  }
}

variable "signalr_sku" {
  description = "Azure SignalR Service SKU. Standard_S1 required for >20 concurrent connections and for 99.9% SLA; Free_F1 is only acceptable in dev."
  type = object({
    name     = string
    capacity = number
  })
  default = {
    name     = "Standard_S1"
    capacity = 1
  }
}

variable "sql_sku_name" {
  description = "Azure SQL database SKU (e.g. S1, GP_S_Gen5_2 for serverless)."
  type        = string
  default     = "S1"
}

variable "sql_max_size_gb" {
  description = "Max data size for the telemetry database."
  type        = number
  default     = 32
}

variable "functions_plan_sku" {
  description = "Service plan SKU for the Function Apps. EP1 (Elastic Premium) is the default because Consumption cold-start jeopardises the 30s alert SLA (ADR-002)."
  type        = string
  default     = "EP1"
}

variable "functions_prewarmed_instances" {
  description = "Pre-warmed instances on the Elastic Premium plan. >=1 keeps the ingest path hot."
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Retention / SLO knobs
# ---------------------------------------------------------------------------

variable "reading_retention_days" {
  description = "How long raw sensor readings are kept. UI only needs 24h; 30d gives QA/incident headroom."
  type        = number
  default     = 30

  validation {
    condition     = var.reading_retention_days >= 2
    error_message = "reading_retention_days must be at least 2 so the 24h chart window is always fully covered."
  }
}

variable "device_offline_after_seconds" {
  description = "A device with no telemetry for this long is reported offline. Default 90s = 3x the expected 30s telemetry interval."
  type        = number
  default     = 90
}

# ---------------------------------------------------------------------------
# Device credentials (acceptance criterion 5)
# ---------------------------------------------------------------------------

variable "device_root_ca_pem" {
  description = <<-EOT
    PEM of the root/intermediate CA that signs per-device X.509 certificates. Supplied
    by the pipeline from Key Vault, never committed. When null, DPS is provisioned but
    the CA upload + enrollment group is left to infra/scripts/bootstrap-dps.sh.
  EOT
  type        = string
  sensitive   = true
  default     = null
}

variable "sql_use_password_auth" {
  description = <<-EOT
    Escape hatch. When false (default) the Function Apps reach SQL with their managed
    identity and no secret exists at runtime. When true, the connection password is
    injected as a Key Vault reference app setting - still never inline in code or state
    output.
  EOT
  type        = bool
  default     = false
}

variable "alert_email_receivers" {
  description = "Map of receiver name => email address paged when the ingest or API path degrades."
  type        = map(string)
  default     = {}
}

variable "allowed_cors_origins" {
  description = "Extra origins allowed to call the API (the Static Web App origin is added automatically)."
  type        = list(string)
  default     = []
}
