# ---------------------------------------------------------------------------
# Azure Static Web Apps hosts the Angular SPA.
#
# Chosen over App Service because the frontend is a pure static bundle: SWA gives
# global CDN delivery, free managed TLS, PR preview environments, and per-branch
# staging with no plan to size. Trade-off: SWA cannot terminate Entra tokens for our
# own API and its managed auth is deliberately unused (ADR-003), so the SPA talks to
# the Function App on a separate origin with CORS. That costs one preflight per new
# route and requires the API origin in the CSP - accepted in exchange for keeping a
# single, testable token-validation path in the API.
# ---------------------------------------------------------------------------
resource "azurerm_static_web_app" "spa" {
  name                = "stapp-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  sku_tier = var.sku_tier
  sku_size = var.sku_tier

  # No repository token here. CI deploys with a federated (OIDC) credential; the
  # deployment token is read from Key Vault by the pipeline when a token is required.
  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    # Public, non-secret configuration only. Anything sensitive would be a Key Vault
    # reference resolved server-side, never shipped to a browser.
    API_BASE_URL = var.api_base_url
  }
}
