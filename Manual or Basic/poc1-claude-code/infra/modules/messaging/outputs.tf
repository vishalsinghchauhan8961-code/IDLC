output "iothub_id" {
  value = azurerm_iothub.main.id
}

output "iothub_name" {
  value = azurerm_iothub.main.name
}

output "iothub_hostname" {
  value = azurerm_iothub.main.hostname
}

# Fully-qualified namespace of the built-in Event Hub-compatible endpoint. The ingest
# Function binds to this with an identity-based connection, so no connection string
# (and therefore no secret) is ever placed in app settings.
output "iothub_events_fqdn" {
  value = "${azurerm_iothub.main.name}.servicebus.windows.net"
}

output "iothub_events_consumer_group" {
  value = azurerm_iothub_consumer_group.ingest.name
}

output "dps_id" {
  value = azurerm_iothub_dps.main.id
}

output "dps_id_scope" {
  value = azurerm_iothub_dps.main.id_scope
}

output "signalr_id" {
  value = azurerm_signalr_service.main.id
}

output "signalr_hostname" {
  value = azurerm_signalr_service.main.hostname
}

output "eventgrid_system_topic_name" {
  value = azurerm_eventgrid_system_topic.iothub.name
}
