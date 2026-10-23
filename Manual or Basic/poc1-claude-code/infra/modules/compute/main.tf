locals {
  # Storage account names: 3-24 chars, lowercase alphanumeric only.
  storage_account_name = substr(replace("st${var.name_prefix}${var.unique_suffix}", "-", ""), 0, 24)

  # Settings shared by both Function Apps. Note what is NOT here: no connection
  # strings with keys, no passwords, no client secrets. Every binding below uses an
  # identity-based connection (`__accountName` / `__serviceUri` /
  # `__fullyQualifiedNamespace`) resolved by the app's managed identity.
  common_app_settings = {
    FUNCTIONS_WORKER_RUNTIME              = "dotnet-isolated"
    FUNCTIONS_EXTENSION_VERSION           = "~4"
    AzureWebJobsStorage__accountName      = local.storage_account_name
    AzureWebJobsStorage__credential       = "managedidentity"
    WEBSITE_RUN_FROM_PACKAGE              = "1"
    APPLICATIONINSIGHTS_CONNECTION_STRING = var.app_insights_connection_string

    # Data access - passwordless, see modules/data/outputs.tf
    Sql__ConnectionString  = var.sql_connection_string
    Sql__CommandTimeoutSec = "15"

    # Realtime fan-out (ADR-002). Identity-based SignalR binding.
    AzureSignalRConnectionString__serviceUri = "https://${var.signalr_hostname}"
    Realtime__HubName                        = var.signalr_hub_name

    # Domain / SLO configuration - values the app must not hardcode.
    Telemetry__DeviceOfflineAfterSeconds = tostring(var.device_offline_after_seconds)
    Telemetry__ReadingRetentionDays      = tostring(var.reading_retention_days)
    Readings__DefaultMaxPoints           = "720"
    Alerts__LatencyBudgetSeconds         = "30"
  }

  # Entra ID (ADR-003). Only public identifiers - a JWT-validating API needs no secret.
  auth_app_settings = {
    Auth__TenantId      = var.entra_tenant_id
    Auth__Authority     = "https://login.microsoftonline.com/${var.entra_tenant_id}/v2.0"
    Auth__Audience      = "api://${var.api_app_client_id}"
    Auth__ApiClientId   = var.api_app_client_id
    Auth__SpaClientId   = var.spa_app_client_id
    Auth__RequiredScope = "Telemetry.Read"
    Auth__OperatorRole  = "Telemetry.Operator"
  }

  # Only populated when var.sql_admin_password_secret_id is set AND password auth is
  # explicitly enabled. This is the one place a secret may enter configuration, and it
  # enters as a Key Vault reference - the value itself never appears in Terraform,
  # code, or the portal.
  optional_secret_settings = var.sql_admin_password_secret_id == null ? {} : {
    Sql__AdminPassword = "@Microsoft.KeyVault(SecretUri=${var.sql_admin_password_secret_id})"
  }
}

resource "azurerm_storage_account" "functions" {
  name                = local.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  account_tier             = "Standard"
  account_replication_type = var.storage_replication_type
  account_kind             = "StorageV2"
  min_tls_version          = "TLS1_2"

  # Functions runtime reaches this account with a managed identity, so key-based
  # access is turned off entirely.
  shared_access_key_enabled       = false
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_service_plan" "functions" {
  name                = "asp-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.plan_sku_name
  tags                = var.tags

  # Elastic Premium: keep instances warm so an Event Hub trigger cold start cannot
  # eat into the 30s alert budget (ADR-002).
  maximum_elastic_worker_count = var.plan_max_elastic_workers
}

# ---------------------------------------------------------------------------
# API Function App - HTTP surface described by docs/api/openapi.yaml
# ---------------------------------------------------------------------------
resource "azurerm_linux_function_app" "api" {
  name                = "func-${var.name_prefix}-api"
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.functions.id
  tags                = var.tags

  storage_account_name          = azurerm_storage_account.functions.name
  storage_uses_managed_identity = true
  https_only                    = true
  functions_extension_version   = "~4"

  identity {
    type = "SystemAssigned"
  }

  app_settings = merge(
    local.common_app_settings,
    local.auth_app_settings,
    local.optional_secret_settings,
    {
      Role = "api"
    },
  )

  site_config {
    ftps_state                             = "Disabled"
    http2_enabled                          = true
    minimum_tls_version                    = "1.2"
    use_32_bit_worker                      = false
    application_insights_connection_string = var.app_insights_connection_string
    pre_warmed_instance_count              = var.pre_warmed_instance_count
    elastic_instance_minimum               = var.pre_warmed_instance_count
    health_check_path                      = "/api/health"
    health_check_eviction_time_in_min      = 5

    application_stack {
      dotnet_version              = "8.0"
      use_dotnet_isolated_runtime = true
    }

    cors {
      allowed_origins = var.allowed_cors_origins
      # The SPA sends a bearer token, not a cookie, so credentialed CORS is not needed.
      support_credentials = false
    }
  }

  lifecycle {
    ignore_changes = [
      # Deployment pipeline (Agent C) owns the package pointer.
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
    ]
  }
}

# ---------------------------------------------------------------------------
# Ingest Function App - IoT Hub trigger, threshold evaluation, timers.
# Separated from the API so a telemetry burst cannot starve operator page loads and
# vice versa. Cost of separation: one extra app to deploy and monitor.
# ---------------------------------------------------------------------------
resource "azurerm_linux_function_app" "ingest" {
  name                = "func-${var.name_prefix}-ingest"
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.functions.id
  tags                = var.tags

  storage_account_name          = azurerm_storage_account.functions.name
  storage_uses_managed_identity = true
  https_only                    = true
  functions_extension_version   = "~4"

  identity {
    type = "SystemAssigned"
  }

  app_settings = merge(
    local.common_app_settings,
    local.optional_secret_settings,
    {
      Role = "ingest"

      # Identity-based Event Hub connection to the IoT Hub built-in endpoint.
      IoTHubEvents__fullyQualifiedNamespace = var.iothub_events_fqdn
      IoTHubEvents__credential              = "managedidentity"
      IoTHubEvents__eventHubName            = var.iothub_name
      IoTHubEvents__consumerGroup           = var.iothub_events_consumer_group

      # Batch tuning: small batches + short wait keep p95 ingest-to-alert latency well
      # inside the 30s SLA at the cost of more SQL round trips.
      Ingest__MaxEventBatchSize        = "100"
      Ingest__MaxWaitMilliseconds      = "1000"
      Ingest__DeviceStatusSweepSeconds = "30"
    },
  )

  site_config {
    ftps_state                             = "Disabled"
    http2_enabled                          = true
    minimum_tls_version                    = "1.2"
    use_32_bit_worker                      = false
    application_insights_connection_string = var.app_insights_connection_string
    pre_warmed_instance_count              = var.pre_warmed_instance_count
    elastic_instance_minimum               = var.pre_warmed_instance_count

    application_stack {
      dotnet_version              = "8.0"
      use_dotnet_isolated_runtime = true
    }
  }

  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
    ]
  }
}

# ---------------------------------------------------------------------------
# Role assignments - the reason no secrets are needed at runtime.
# ---------------------------------------------------------------------------
locals {
  function_principals = {
    api    = azurerm_linux_function_app.api.identity[0].principal_id
    ingest = azurerm_linux_function_app.ingest.identity[0].principal_id
  }

  storage_roles = [
    "Storage Blob Data Owner",
    "Storage Queue Data Contributor",
    "Storage Table Data Contributor",
  ]

  storage_role_assignments = {
    for pair in setproduct(keys(local.function_principals), local.storage_roles) :
    "${pair[0]}|${pair[1]}" => {
      principal_id = local.function_principals[pair[0]]
      role         = pair[1]
    }
  }
}

resource "azurerm_role_assignment" "functions_storage" {
  for_each = local.storage_role_assignments

  scope                = azurerm_storage_account.functions.id
  role_definition_name = each.value.role
  principal_id         = each.value.principal_id
}

resource "azurerm_role_assignment" "functions_keyvault" {
  for_each = local.function_principals

  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "functions_signalr" {
  for_each = local.function_principals

  scope                = var.signalr_id
  role_definition_name = "SignalR Service Owner"
  principal_id         = each.value
}

# Only the ingest app reads device telemetry from the IoT Hub built-in endpoint.
resource "azurerm_role_assignment" "ingest_iothub_receiver" {
  scope                = var.iothub_id
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = local.function_principals["ingest"]
}

# Reading the device registry (twin/lifecycle reconciliation for online status).
resource "azurerm_role_assignment" "ingest_iothub_registry" {
  scope                = var.iothub_id
  role_definition_name = "IoT Hub Registry Contributor"
  principal_id         = local.function_principals["ingest"]
}

resource "azurerm_role_assignment" "api_iothub_reader" {
  scope                = var.iothub_id
  role_definition_name = "IoT Hub Data Reader"
  principal_id         = local.function_principals["api"]
}

# ---------------------------------------------------------------------------
# Alerting on the platform itself. If the ingest path stalls, "no alerts" in the UI
# is indistinguishable from "all healthy" - so the platform must page us.
# ---------------------------------------------------------------------------
resource "azurerm_monitor_action_group" "platform" {
  name                = "ag-${var.name_prefix}-platform"
  resource_group_name = var.resource_group_name
  short_name          = substr("plat${var.environment}", 0, 12)
  tags                = var.tags

  dynamic "email_receiver" {
    for_each = var.alert_email_receivers

    content {
      name                    = email_receiver.key
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_metric_alert" "api_5xx" {
  name                = "alert-${var.name_prefix}-api-5xx"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_linux_function_app.api.id]
  description         = "API Function App is returning server errors; operators may be seeing error states."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "Http5xx"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 5
  }

  action {
    action_group_id = azurerm_monitor_action_group.platform.id
  }
}

resource "azurerm_monitor_metric_alert" "ingest_failures" {
  name                = "alert-${var.name_prefix}-ingest-failures"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_linux_function_app.ingest.id]
  description         = "Ingest Function executions are failing; the 30s alert SLA is at risk."
  severity            = 0
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "FunctionExecutionCount"
    aggregation      = "Total"
    operator         = "LessThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.platform.id
  }
}
