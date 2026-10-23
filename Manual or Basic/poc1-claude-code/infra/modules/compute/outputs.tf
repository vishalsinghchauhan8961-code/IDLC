output "api_function_app_id" {
  value = azurerm_linux_function_app.api.id
}

output "api_function_app_name" {
  value = azurerm_linux_function_app.api.name
}

output "api_base_url" {
  description = "Base URL the SPA calls. Routes are relative to this (see docs/api/openapi.yaml)."
  value       = "https://${azurerm_linux_function_app.api.default_hostname}/api"
}

output "api_principal_id" {
  value = azurerm_linux_function_app.api.identity[0].principal_id
}

output "ingest_function_app_id" {
  value = azurerm_linux_function_app.ingest.id
}

output "ingest_function_app_name" {
  value = azurerm_linux_function_app.ingest.name
}

output "ingest_principal_id" {
  value = azurerm_linux_function_app.ingest.identity[0].principal_id
}

output "managed_identity_principal_ids" {
  description = "Both Function App identities. The SQL bootstrap script creates a contained DB user for each."
  value       = local.function_principals
}

output "action_group_id" {
  value = azurerm_monitor_action_group.platform.id
}
