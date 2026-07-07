locals {
  search_name = "${var.name_prefix}search"
}

# Azure AI Search for agent vector stores (BYO search).
resource "azapi_resource" "ai_search" {
  count = var.byo_data ? 1 : 0

  type                      = "Microsoft.Search/searchServices@2025-05-01"
  name                      = local.search_name
  parent_id                 = local.rg_id
  location                  = var.location
  schema_validation_enabled = true

  body = {
    sku = {
      name = "standard"
    }
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      replicaCount   = 1
      partitionCount = 1
      hostingMode    = "Default"
      semanticSearch = "disabled"

      disableLocalAuth = false
      authOptions = {
        aadOrApiKey = {
          aadAuthFailureMode = "http401WithBearerChallenge"
        }
      }

      publicNetworkAccess = "Disabled"
      networkRuleSet = {
        bypass = "None"
      }
    }
  }

  response_export_values = ["identity.principalId"]
}

########################################################################
# Private endpoint
########################################################################

resource "azurerm_private_endpoint" "pe_aisearch" {
  count = var.byo_data ? 1 : 0

  name                = "${azapi_resource.ai_search[0].name}-pe"
  location            = var.location
  resource_group_name = local.rg_name
  subnet_id           = local.pe_subnet_id

  private_service_connection {
    name                           = "${azapi_resource.ai_search[0].name}-plsc"
    private_connection_resource_id = azapi_resource.ai_search[0].id
    subresource_names              = ["searchService"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "${azapi_resource.ai_search[0].name}-dns"
    private_dns_zone_ids = [local.dns_zone_ids.search]
  }

  depends_on = [azurerm_private_endpoint.pe_cosmosdb]
}

########################################################################
# Project managed-identity role assignments
########################################################################

resource "azurerm_role_assignment" "search_index_data_contributor" {
  count = var.byo_data ? 1 : 0

  name                 = uuidv5("dns", "${local.project_name}${local.project_principal_id}${azapi_resource.ai_search[0].name}searchindexdatacontributor")
  scope                = azapi_resource.ai_search[0].id
  role_definition_name = "Search Index Data Contributor"
  principal_id         = local.project_principal_id

  depends_on = [time_sleep.wait_project_identities]
}

resource "azurerm_role_assignment" "search_service_contributor" {
  count = var.byo_data ? 1 : 0

  name                 = uuidv5("dns", "${local.project_name}${local.project_principal_id}${azapi_resource.ai_search[0].name}searchservicecontributor")
  scope                = azapi_resource.ai_search[0].id
  role_definition_name = "Search Service Contributor"
  principal_id         = local.project_principal_id

  depends_on = [time_sleep.wait_project_identities]
}
