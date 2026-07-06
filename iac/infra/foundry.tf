locals {
  foundry_name         = "${var.name_prefix}aifoundry"
  project_name         = "${var.name_prefix}proj"
  project_principal_id = azapi_resource.ai_foundry_project.output.identity.principalId
}

########################################################################
# Microsoft Foundry account (Cognitive Services / AIServices)
########################################################################

# The Foundry account is created with VNet injection ("agent" scenario) so the
# agent runtime and single-tenant data proxy consume IPs from the delegated
# agent subnet and egress to customer resources through private endpoints.
resource "azapi_resource" "ai_foundry" {
  type                      = "Microsoft.CognitiveServices/accounts@2025-06-01"
  name                      = local.foundry_name
  parent_id                 = azurerm_resource_group.rg.id
  location                  = var.location
  schema_validation_enabled = false

  body = {
    kind = "AIServices"
    sku = {
      name = "S0"
    }
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      # Allow both Entra ID and key auth on the underlying Cognitive account.
      disableLocalAuth = false

      # Mark this as a Foundry resource (enables projects).
      allowProjectManagement = true

      # Custom subdomain is required for private DNS resolution.
      customSubDomainName = local.foundry_name

      # Ingress: private (Disabled + private endpoint) or public, per variable.
      # Egress is always private via the agent VNet injection below.
      publicNetworkAccess = var.foundry_public_network_access ? "Enabled" : "Disabled"
      networkAcls = {
        defaultAction = "Allow"
      }

      # VNet injection for the Standard Agent runtime (egress via subnet).
      networkInjections = [
        {
          scenario                   = "agent"
          subnetArmId                = local.agent_subnet_id
          useMicrosoftManagedNetwork = false
        }
      ]
    }
  }

  response_export_values = ["identity.principalId"]

  depends_on = [
    azapi_resource_action.purge_ai_foundry
  ]
}

########################################################################
# Wait for the account to finish provisioning
#
# With VNet injection the account keeps provisioning after the create call
# returns (provisioningState stays "Accepted" for a while). Creating a
# dependent too early fails with AccountProvisioningStateInvalid, so gate the
# model deployment, Foundry private endpoint and project on this wait.
########################################################################

resource "time_sleep" "wait_foundry_account" {
  create_duration = "180s"

  depends_on = [azapi_resource.ai_foundry]
}

########################################################################
# Model deployment
########################################################################

resource "azurerm_cognitive_deployment" "model" {
  for_each = { for m in var.model_deployment : m.name => m }

  depends_on = [time_sleep.wait_foundry_account]

  name                 = each.value.name
  cognitive_account_id = azapi_resource.ai_foundry.id

  sku {
    name     = each.value.sku_name
    capacity = each.value.sku_capacity
  }

  model {
    format  = each.value.format
    name    = each.value.model_name
    version = each.value.version
  }
}

########################################################################
# Foundry project
########################################################################

resource "azapi_resource" "ai_foundry_project" {
  type                      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name                      = local.project_name
  parent_id                 = azapi_resource.ai_foundry.id
  location                  = var.location
  schema_validation_enabled = false

  body = {
    sku = {
      name = "S0"
    }
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      displayName = local.project_name
      description = "Network-secured Foundry Agent project (private egress via subnet)."
    }
  }

  response_export_values = [
    "identity.principalId",
    "properties.internalId",
  ]

  depends_on = [
    time_sleep.wait_foundry_account,
    azurerm_private_endpoint.pe_storage,
    azurerm_private_endpoint.pe_cosmosdb,
    azurerm_private_endpoint.pe_aisearch,
    azurerm_private_endpoint.pe_aifoundry,
  ]
}

# Allow the project's system-assigned identity to replicate through Entra ID.
resource "time_sleep" "wait_project_identities" {
  depends_on      = [azapi_resource.ai_foundry_project]
  create_duration = "10s"
}

########################################################################
# Project connections to the BYO data resources (AAD auth)
########################################################################

resource "azapi_resource" "conn_cosmosdb" {
  count = var.byo_data ? 1 : 0

  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name                      = azurerm_cosmosdb_account.cosmosdb[0].name
  parent_id                 = azapi_resource.ai_foundry_project.id
  schema_validation_enabled = false

  body = {
    name = azurerm_cosmosdb_account.cosmosdb[0].name
    properties = {
      category = "CosmosDb"
      target   = azurerm_cosmosdb_account.cosmosdb[0].endpoint
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_cosmosdb_account.cosmosdb[0].id
        location   = var.location
      }
    }
  }

  depends_on = [azapi_resource.ai_foundry_project]
}

resource "azapi_resource" "conn_storage" {
  count = var.byo_data ? 1 : 0

  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name                      = azurerm_storage_account.storage_account[0].name
  parent_id                 = azapi_resource.ai_foundry_project.id
  schema_validation_enabled = false

  body = {
    name = azurerm_storage_account.storage_account[0].name
    properties = {
      category = "AzureStorageAccount"
      target   = azurerm_storage_account.storage_account[0].primary_blob_endpoint
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_storage_account.storage_account[0].id
        location   = var.location
      }
    }
  }

  depends_on = [azapi_resource.ai_foundry_project]
}

resource "azapi_resource" "conn_aisearch" {
  count = var.byo_data ? 1 : 0

  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name                      = azapi_resource.ai_search[0].name
  parent_id                 = azapi_resource.ai_foundry_project.id
  schema_validation_enabled = false

  body = {
    name = azapi_resource.ai_search[0].name
    properties = {
      category = "CognitiveSearch"
      target   = "https://${azapi_resource.ai_search[0].name}.search.windows.net"
      authType = "AAD"
      metadata = {
        ApiType    = "Azure"
        ApiVersion = "2025-05-01-preview"
        ResourceId = azapi_resource.ai_search[0].id
        location   = var.location
      }
    }
  }

  depends_on = [azapi_resource.ai_foundry_project]
}

########################################################################
# RBAC propagation gate
########################################################################

# Allow the project role assignments (defined in storage.tf, cosmos.tf and
# search.tf) to propagate before creating the capability host. Only relevant
# for the Standard setup (byo_data = true).
resource "time_sleep" "wait_rbac" {
  count = var.byo_data ? 1 : 0

  create_duration = "60s"

  depends_on = [
    azurerm_role_assignment.cosmosdb_operator,
    azurerm_role_assignment.storage_blob_data_contributor,
    azurerm_role_assignment.search_index_data_contributor,
    azurerm_role_assignment.search_service_contributor,
  ]
}

########################################################################
# Capability hosts
#
# Standard (byo_data = true): an account-level capability host plus a
# project-level host wired to the Storage / Cosmos DB / AI Search connections.
# Basic (byo_data = false): only a project-level host with no connections
# (platform-managed data).
########################################################################

resource "azapi_resource" "ai_foundry_account_capability_host" {
  count = var.byo_data ? 1 : 0

  type                      = "Microsoft.CognitiveServices/accounts/capabilityHosts@2025-04-01-preview"
  name                      = "caphostacct"
  parent_id                 = azapi_resource.ai_foundry.id
  schema_validation_enabled = false

  body = {
    properties = {
      capabilityHostKind = "Agents"
    }
  }

  depends_on = [azapi_resource.ai_foundry]
}

resource "azapi_resource" "ai_foundry_project_capability_host" {
  type                      = "Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview"
  name                      = "caphostproj"
  parent_id                 = azapi_resource.ai_foundry_project.id
  schema_validation_enabled = false

  body = {
    properties = merge(
      { capabilityHostKind = "Agents" },
      var.byo_data ? {
        vectorStoreConnections   = azapi_resource.ai_search[*].name
        storageConnections       = azurerm_storage_account.storage_account[*].name
        threadStorageConnections = azurerm_cosmosdb_account.cosmosdb[*].name
      } : {}
    )
  }

  depends_on = [
    azapi_resource.ai_foundry_account_capability_host,
    azapi_resource.conn_aisearch,
    azapi_resource.conn_cosmosdb,
    azapi_resource.conn_storage,
    time_sleep.wait_rbac,
  ]
}

########################################################################
# Destroy-time purge
#
# Purging the Foundry account on destroy removes the agent subnet's
# serviceAssociationLink (legionservicelink), which otherwise blocks the
# subnet (and VNet) from being deleted. The cooldown gives the backend time
# to release the link before the subnet is removed.
########################################################################

resource "time_sleep" "purge_ai_foundry_cooldown" {
  destroy_duration = "900s"

  depends_on = [
    azurerm_subnet.subnet_agent,
  ]
}

resource "azapi_resource_action" "purge_ai_foundry" {
  type        = "Microsoft.CognitiveServices/locations/resourceGroups/deletedAccounts@2021-04-30"
  resource_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.CognitiveServices/locations/${var.location}/resourceGroups/${azurerm_resource_group.rg.name}/deletedAccounts/${local.foundry_name}"
  method      = "DELETE"
  when        = "destroy"

  depends_on = [time_sleep.purge_ai_foundry_cooldown]
}

########################################################################
# Private endpoint
########################################################################

resource "azurerm_private_endpoint" "pe_aifoundry" {
  count = var.foundry_public_network_access ? 0 : 1

  name                = "${azapi_resource.ai_foundry.name}-pe"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = local.pe_subnet_id

  private_service_connection {
    name                           = "${azapi_resource.ai_foundry.name}-plsc"
    private_connection_resource_id = azapi_resource.ai_foundry.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "${azapi_resource.ai_foundry.name}-dns"
    private_dns_zone_ids = [
      local.dns_zone_ids.cognitiveservices,
      local.dns_zone_ids.ai_services,
      local.dns_zone_ids.openai,
    ]
  }

  depends_on = [
    azurerm_private_endpoint.pe_aisearch,
    time_sleep.wait_foundry_account,
  ]
}
