locals {
  storage_name = "${var.name_prefix}storage"
}

# Storage account for agent file storage (BYO storage).
resource "azurerm_storage_account" "storage_account" {
  count = var.byo_data ? 1 : 0

  name                = local.storage_name
  resource_group_name = local.rg_name
  location            = var.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "ZRS"

  # Force Entra ID auth: disable shared keys and public blob access.
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

########################################################################
# Private endpoint
########################################################################

resource "azurerm_private_endpoint" "pe_storage" {
  count = var.byo_data ? 1 : 0

  name                = "${azurerm_storage_account.storage_account[0].name}-pe"
  location            = var.location
  resource_group_name = local.rg_name
  subnet_id           = local.pe_subnet_id

  private_service_connection {
    name                           = "${azurerm_storage_account.storage_account[0].name}-plsc"
    private_connection_resource_id = azurerm_storage_account.storage_account[0].id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "${azurerm_storage_account.storage_account[0].name}-dns"
    private_dns_zone_ids = [local.dns_zone_ids.blob]
  }
}

########################################################################
# Project managed-identity role assignments
########################################################################

resource "azurerm_role_assignment" "storage_blob_data_contributor" {
  count = var.byo_data ? 1 : 0

  name                 = uuidv5("dns", "${local.project_name}${local.project_principal_id}${azurerm_storage_account.storage_account[0].name}storageblobdatacontributor")
  scope                = azurerm_storage_account.storage_account[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.project_principal_id

  depends_on = [time_sleep.wait_project_identities]
}

# Storage Blob Data Owner, scoped via ABAC to the project's agent containers.
resource "azurerm_role_assignment" "storage_blob_data_owner" {
  count = var.byo_data ? 1 : 0

  name                 = uuidv5("dns", "${local.project_name}${local.project_principal_id}${azurerm_storage_account.storage_account[0].name}storageblobdataowner")
  scope                = azurerm_storage_account.storage_account[0].id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = local.project_principal_id

  condition_version = "2.0"
  condition         = <<-EOT
  (
    (
      !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read'})
      AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action'})
      AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write'})
    )
    OR
    (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase '${azapi_resource.ai_foundry_project.output.properties.internalId}'
    AND @Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringLikeIgnoreCase '*-azureml-agent')
  )
  EOT

  depends_on = [azapi_resource.ai_foundry_project_capability_host]
}
