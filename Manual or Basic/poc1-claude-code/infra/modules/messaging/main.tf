# ---------------------------------------------------------------------------
# IoT Hub - device telemetry ingest (acceptance criteria 2, 3, 5)
# ---------------------------------------------------------------------------
resource "azurerm_iothub" "main" {
  name                = "iot-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  sku {
    name     = var.iothub_sku.name
    capacity = var.iothub_sku.capacity
  }

  # TRADE-OFF (ADR-001): we would prefer local_authentication_enabled = false so a
  # shared key is structurally impossible. We cannot: linking a Device Provisioning
  # Service to a hub requires a SAS-based service connection string, and DPS is how we
  # issue the per-device X.509 identities that acceptance criterion 5 demands. So local
  # auth stays on, and criterion 5 is enforced by the DPS enrollment group using X.509
  # attestation only (no symmetric-key enrollment). Residual risk is the service-side
  # SAS policy below, mitigated by: least-privilege permissions, no device_connect,
  # the string is only ever read by Terraform/DPS, and every application component uses
  # managed identity instead.
  local_authentication_enabled = true

  # Partitions cannot be changed after creation. 4 gives the ingest Function room to
  # scale to 4 concurrent consumers, which is well past the throughput this slice needs.
  event_hub_partition_count   = 4
  event_hub_retention_in_days = 1

  cloud_to_device {
    max_delivery_count = 10
    default_ttl        = "PT1H"

    feedback {
      time_to_live       = "PT1H10M"
      max_delivery_count = 10
    }
  }
}

# Dedicated consumer group so the ingest Function never competes with ad-hoc
# diagnostic readers on the built-in endpoint.
resource "azurerm_iothub_consumer_group" "ingest" {
  name                   = "ingestfn"
  resource_group_name    = var.resource_group_name
  iothub_name            = azurerm_iothub.main.name
  eventhub_endpoint_name = "events"
}

resource "azurerm_iothub_consumer_group" "diagnostics" {
  name                   = "diagnostics"
  resource_group_name    = var.resource_group_name
  iothub_name            = azurerm_iothub.main.name
  eventhub_endpoint_name = "events"
}

# Least-privilege policy used exclusively to link DPS to the hub. It intentionally
# omits device_connect, so this key cannot be used to impersonate a device.
resource "azurerm_iothub_shared_access_policy" "dps_link" {
  name                = "dps-link"
  resource_group_name = var.resource_group_name
  iothub_name         = azurerm_iothub.main.name

  registry_read   = true
  registry_write  = true
  service_connect = true
  device_connect  = false
}

# ---------------------------------------------------------------------------
# Device Provisioning Service - issues the per-device identity (criterion 5)
# ---------------------------------------------------------------------------
resource "azurerm_iothub_dps" "main" {
  name                = "dps-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_policy   = "Hashed"
  tags                = var.tags

  sku {
    name     = "S1"
    capacity = 1
  }

  linked_hub {
    connection_string = azurerm_iothub_shared_access_policy.dps_link.primary_connection_string
    location          = var.location
    allocation_weight = 1
  }
}

# The CA that signs per-device leaf certs. The PEM is supplied by the pipeline from
# Key Vault (var.device_root_ca_pem) - it is never committed. When absent, DPS is
# still created and infra/scripts/bootstrap-dps.sh completes the CA + enrollment
# group step (the azurerm provider has no enrollment-group resource; see ADR-001).
resource "azurerm_iothub_dps_certificate" "device_root_ca" {
  count = var.device_root_ca_pem == null ? 0 : 1

  name                = "device-root-ca"
  resource_group_name = var.resource_group_name
  iot_dps_name        = azurerm_iothub_dps.main.name
  certificate_content = base64encode(var.device_root_ca_pem)
}

# ---------------------------------------------------------------------------
# SignalR Service - realtime push to the browser (ADR-002)
# ---------------------------------------------------------------------------
resource "azurerm_signalr_service" "main" {
  name                = "sigr-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  sku {
    name     = var.signalr_sku.name
    capacity = var.signalr_sku.capacity
  }

  # Serverless mode: no persistent app server. Azure Functions publishes through the
  # SignalR output binding and the browser negotiates via POST /realtime/negotiate.
  service_mode              = "Serverless"
  connectivity_logs_enabled = true
  messaging_logs_enabled    = true

  # Clients authenticate with an Entra-derived access token minted by the negotiate
  # Function, so shared keys are not needed at runtime.
  local_auth_enabled            = false
  public_network_access_enabled = true

  cors {
    allowed_origins = var.signalr_allowed_origins
  }
}

# ---------------------------------------------------------------------------
# Event Grid system topic - fast device connected/disconnected signal.
# Treated as an accelerator only: these events are not ordering-guaranteed, so the
# telemetry heartbeat watermark in SQL remains the source of truth for online/offline.
# ---------------------------------------------------------------------------
resource "azurerm_eventgrid_system_topic" "iothub" {
  name                   = "egst-${var.name_prefix}-iot"
  resource_group_name    = var.resource_group_name
  location               = var.location
  source_arm_resource_id = azurerm_iothub.main.id
  topic_type             = "Microsoft.Devices.IoTHubs"
  tags                   = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "iothub" {
  name                       = "diag-iothub"
  target_resource_id         = azurerm_iothub.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "Connections"
  }

  enabled_log {
    category = "DeviceTelemetry"
  }

  enabled_log {
    category = "D2CTwinOperations"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "signalr" {
  name                       = "diag-signalr"
  target_resource_id         = azurerm_signalr_service.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AllLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
