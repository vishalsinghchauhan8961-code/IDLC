output "spa_id" {
  value = azurerm_static_web_app.spa.id
}

output "spa_hostname" {
  value = azurerm_static_web_app.spa.default_host_name
}

output "spa_origin" {
  description = "Origin the API must allow via CORS and the SignalR service must accept."
  value       = "https://${azurerm_static_web_app.spa.default_host_name}"
}
