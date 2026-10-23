# Outputs are the contract between this stage and Agent C's deployment pipeline.
# None of them carry a credential.

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "api_base_url" {
  description = "Set this as API_BASE_URL in the Angular environment file."
  value       = module.compute.api_base_url
}

output "api_function_app_name" {
  value = module.compute.api_function_app_name
}

output "ingest_function_app_name" {
  value = module.compute.ingest_function_app_name
}

output "spa_origin" {
  value = module.frontend.spa_origin
}

output "sql_server_fqdn" {
  value = module.data.server_fqdn
}

output "sql_database_name" {
  value = module.data.database_name
}

output "sql_connection_string_managed_identity" {
  description = "Passwordless connection string; used by the migration runner and the Function Apps."
  value       = module.data.connection_string_managed_identity
}

output "function_app_principal_ids" {
  description = "Feed these to infra/scripts/bootstrap-sql.sh so each identity gets a least-privilege DB user."
  value       = module.compute.managed_identity_principal_ids
}

output "iothub_name" {
  value = module.messaging.iothub_name
}

output "iothub_hostname" {
  value = module.messaging.iothub_hostname
}

output "dps_id_scope" {
  description = "Devices need this (plus their own X.509 cert) to provision. Not a secret."
  value       = module.messaging.dps_id_scope
}

output "signalr_hostname" {
  value = module.messaging.signalr_hostname
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "app_insights_connection_string" {
  value     = module.observability.app_insights_connection_string
  sensitive = true
}
