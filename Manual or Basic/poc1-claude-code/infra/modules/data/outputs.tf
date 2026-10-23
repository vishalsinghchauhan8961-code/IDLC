output "server_id" {
  value = azurerm_mssql_server.main.id
}

output "server_fqdn" {
  value = azurerm_mssql_server.main.fully_qualified_domain_name
}

output "database_name" {
  value = azurerm_mssql_database.telemetry.name
}

output "database_id" {
  value = azurerm_mssql_database.telemetry.id
}

# Passwordless connection string: authentication is the caller's managed identity.
# Contains no credential, which is exactly why it is safe as a plain app setting.
output "connection_string_managed_identity" {
  value = join(";", [
    "Server=tcp:${azurerm_mssql_server.main.fully_qualified_domain_name},1433",
    "Initial Catalog=${azurerm_mssql_database.telemetry.name}",
    "Encrypt=True",
    "TrustServerCertificate=False",
    "Connection Timeout=30",
    "Authentication=Active Directory Default",
  ])
}

output "sql_admin_password_secret_id" {
  description = "Versionless Key Vault secret id for the break-glass password."
  value       = azurerm_key_vault_secret.sql_admin_password.versionless_id
}
