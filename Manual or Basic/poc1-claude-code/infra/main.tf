# ===========================================================================
# Device Telemetry Dashboard - root composition
#
# Architecture and trade-offs: docs/adr/ADR-001-architecture.md
# API contract implemented on top of this: docs/api/openapi.yaml
#
# Everything here is declarative. The only post-apply steps are the two documented
# in ADR-001 (SQL schema migration and the DPS enrollment group), both driven by
# checked-in scripts under infra/scripts and infra/sql - no click-ops.
# ===========================================================================

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  name_prefix = "${var.workload}-${var.environment}"

  base_tags = merge(
    {
      workload    = var.workload
      environment = var.environment
      managed_by  = "terraform"
      owner       = "platform-architect"
      cost_center = "device-telemetry"
    },
    var.tags,
  )

  # Deterministic so the frontend module can be configured with the API URL without
  # depending on the compute module. That keeps the dependency graph acyclic:
  # frontend -> (nothing) -> compute needs the SPA origin for CORS.
  api_base_url = "https://func-${local.name_prefix}-api.azurewebsites.net/api"

  # Localhost origins let Agent C run the SPA against deployed infra during
  # development without disabling CORS.
  dev_origins = var.environment == "prod" ? [] : [
    "http://localhost:4200",
    "https://localhost:4200",
  ]

  cors_origins = distinct(concat(
    [module.frontend.spa_origin],
    local.dev_origins,
    var.allowed_cors_origins,
  ))
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.base_tags
}

# ---------------------------------------------------------------------------
# Key Vault - the single home for every secret in this system.
# RBAC (not access policies) so grants are auditable the same way as the rest of
# Azure, and purge protection so an accidental delete cannot destroy the CA material
# that all device identities chain to.
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "main" {
  name                = substr("kv-${local.name_prefix}-${random_string.suffix.result}", 0, 24)
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tenant_id           = var.entra_tenant_id
  sku_name            = "standard"
  tags                = local.base_tags

  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  public_network_access_enabled = true

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}

# The pipeline identity needs to write the generated SQL password. Scoped to this
# vault only, and it is an Officer (write) grant - the Function Apps get the much
# narrower "Secrets User" (read) role in the compute module.
resource "azurerm_role_assignment" "deployer_kv_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "device_root_ca" {
  count = var.device_root_ca_pem == null ? 0 : 1

  name         = "device-root-ca-pem"
  value        = var.device_root_ca_pem
  key_vault_id = azurerm_key_vault.main.id
  content_type = "application/x-pem-file"
  tags         = local.base_tags

  depends_on = [azurerm_role_assignment.deployer_kv_secrets]
}

# ---------------------------------------------------------------------------
# Modules
# ---------------------------------------------------------------------------
module "observability" {
  source = "./modules/observability"

  name_prefix         = local.name_prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  retention_in_days   = var.environment == "prod" ? 90 : 30
  sampling_percentage = var.environment == "prod" ? 20 : 100
  tags                = local.base_tags
}

module "frontend" {
  source = "./modules/frontend"

  name_prefix         = local.name_prefix
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  sku_tier            = "Standard"
  api_base_url        = local.api_base_url
  tags                = local.base_tags
}

module "messaging" {
  source = "./modules/messaging"

  name_prefix                = local.name_prefix
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  iothub_sku                 = var.iothub_sku
  signalr_sku                = var.signalr_sku
  signalr_allowed_origins    = local.cors_origins
  device_root_ca_pem         = var.device_root_ca_pem
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  tags                       = local.base_tags
}

module "data" {
  source = "./modules/data"

  name_prefix                = local.name_prefix
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = var.entra_tenant_id
  key_vault_id               = azurerm_key_vault.main.id
  entra_admin                = var.sql_entra_admin
  sku_name                   = var.sql_sku_name
  max_size_gb                = var.sql_max_size_gb
  zone_redundant             = var.environment == "prod"
  pitr_retention_days        = var.environment == "prod" ? 14 : 7
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  tags                       = local.base_tags

  depends_on = [azurerm_role_assignment.deployer_kv_secrets]
}

module "compute" {
  source = "./modules/compute"

  name_prefix         = local.name_prefix
  environment         = var.environment
  unique_suffix       = random_string.suffix.result
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.base_tags

  plan_sku_name             = var.functions_plan_sku
  pre_warmed_instance_count = var.functions_prewarmed_instances
  storage_replication_type  = var.environment == "prod" ? "ZRS" : "LRS"

  app_insights_connection_string = module.observability.app_insights_connection_string
  sql_connection_string          = module.data.connection_string_managed_identity
  sql_admin_password_secret_id   = var.sql_use_password_auth ? module.data.sql_admin_password_secret_id : null
  key_vault_id                   = azurerm_key_vault.main.id

  signalr_id       = module.messaging.signalr_id
  signalr_hostname = module.messaging.signalr_hostname
  signalr_hub_name = "telemetry"

  iothub_id                    = module.messaging.iothub_id
  iothub_name                  = module.messaging.iothub_name
  iothub_events_fqdn           = module.messaging.iothub_events_fqdn
  iothub_events_consumer_group = module.messaging.iothub_events_consumer_group

  entra_tenant_id   = var.entra_tenant_id
  api_app_client_id = var.api_app_client_id
  spa_app_client_id = var.spa_app_client_id

  device_offline_after_seconds = var.device_offline_after_seconds
  reading_retention_days       = var.reading_retention_days
  allowed_cors_origins         = local.cors_origins
  alert_email_receivers        = var.alert_email_receivers
}

# ---------------------------------------------------------------------------
# Device connected/disconnected -> ingest Function.
# Wired here (not inside a module) because it is the one edge that needs both the
# messaging and compute modules.
# ---------------------------------------------------------------------------
resource "azurerm_eventgrid_system_topic_event_subscription" "device_connection_state" {
  name                = "sub-device-connection-state"
  system_topic        = module.messaging.eventgrid_system_topic_name
  resource_group_name = azurerm_resource_group.main.name

  included_event_types = [
    "Microsoft.Devices.DeviceConnected",
    "Microsoft.Devices.DeviceDisconnected",
  ]

  azure_function_endpoint {
    function_id                       = "${module.compute.ingest_function_app_id}/functions/DeviceConnectionStateHandler"
    max_events_per_batch              = 10
    preferred_batch_size_in_kilobytes = 64
  }

  retry_policy {
    max_delivery_attempts = 10
    event_time_to_live    = 60
  }
}
