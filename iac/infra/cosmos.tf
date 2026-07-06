locals {
  cosmos_name = "${var.name_prefix}cosmos"
}

# Cosmos DB account for agent thread / message storage (BYO thread storage).
resource "azurerm_cosmosdb_account" "cosmosdb" {
  count = var.byo_data ? 1 : 0

  name                = local.cosmos_name
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  offer_type        = "Standard"
  kind              = "GlobalDocumentDB"
  free_tier_enabled = false

  # Security: Entra ID only, no public access.
  local_authentication_enabled  = false
  public_network_access_enabled = false

  automatic_failover_enabled       = false
  multiple_write_locations_enabled = false

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
    zone_redundant    = false
  }
}

########################################################################
# Private endpoint
########################################################################

resource "azurerm_private_endpoint" "pe_cosmosdb" {
  count = var.byo_data ? 1 : 0

  name                = "${azurerm_cosmosdb_account.cosmosdb[0].name}-pe"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = local.pe_subnet_id

  private_service_connection {
    name                           = "${azurerm_cosmosdb_account.cosmosdb[0].name}-plsc"
    private_connection_resource_id = azurerm_cosmosdb_account.cosmosdb[0].id
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "${azurerm_cosmosdb_account.cosmosdb[0].name}-dns"
    private_dns_zone_ids = [local.dns_zone_ids.cosmos]
  }

  depends_on = [azurerm_private_endpoint.pe_storage]
}

########################################################################
# Project managed-identity role assignments
########################################################################

resource "azurerm_role_assignment" "cosmosdb_operator" {
  count = var.byo_data ? 1 : 0

  name                 = uuidv5("dns", "${local.project_name}${local.project_principal_id}${azurerm_resource_group.rg.name}cosmosdboperator")
  scope                = azurerm_cosmosdb_account.cosmosdb[0].id
  role_definition_name = "Cosmos DB Operator"
  principal_id         = local.project_principal_id

  depends_on = [time_sleep.wait_project_identities]
}

# Cosmos DB SQL built-in Data Contributor (00000000-...-0002) for the
# project identity over the thread/message stores.
resource "azurerm_cosmosdb_sql_role_assignment" "project_cosmos_data_contributor" {
  count = var.byo_data ? 1 : 0

  name                = uuidv5("dns", "${local.project_name}${local.project_principal_id}cosmosdbsqlrole")
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmosdb[0].name
  scope               = azurerm_cosmosdb_account.cosmosdb[0].id
  role_definition_id  = "${azurerm_cosmosdb_account.cosmosdb[0].id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = local.project_principal_id

  depends_on = [azapi_resource.ai_foundry_project_capability_host]
}
