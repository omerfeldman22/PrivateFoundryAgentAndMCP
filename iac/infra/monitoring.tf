########################################################################
# Observability (optional): Log Analytics + Application Insights
########################################################################

locals {
  law_name  = "${var.name_prefix}-law"
  appi_name = "${var.name_prefix}-appi"
}

resource "azurerm_log_analytics_workspace" "law" {
  count = var.enable_application_insights ? 1 : 0

  name                = local.law_name
  location            = var.location
  resource_group_name = local.rg_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "appi" {
  count = var.enable_application_insights ? 1 : 0

  name                = local.appi_name
  location            = var.location
  resource_group_name = local.rg_name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.law[0].id
}
