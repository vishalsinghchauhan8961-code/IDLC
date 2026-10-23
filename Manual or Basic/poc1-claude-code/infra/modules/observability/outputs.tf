output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}

output "app_insights_connection_string" {
  description = "Not a credential in the secret sense, but treated as sensitive so it never lands in plan logs."
  value       = azurerm_application_insights.main.connection_string
  sensitive   = true
}

output "app_insights_id" {
  value = azurerm_application_insights.main.id
}
