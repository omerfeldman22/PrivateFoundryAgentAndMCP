locals {
  # Subnet IDs — pick created subnets or BYO IDs.
  agent_subnet_id = var.create_network ? azurerm_subnet.subnet_agent[0].id : var.subnet_id_agent
  pe_subnet_id    = var.create_network ? azurerm_subnet.subnet_pe[0].id : var.subnet_id_private_endpoint
  aca_subnet_id   = var.create_network ? azurerm_subnet.subnet_aca[0].id : var.subnet_id_aca

  # VNet used for the ACA-environment private DNS zone link.
  dns_link_vnet_id = var.create_network ? azurerm_virtual_network.vnet[0].id : var.vnet_id

  # Private DNS zones to create (key => zone name). The Foundry account zones
  # are only needed for private ingress; the data-resource zones only when
  # byo_data = true.
  base_dns_zones = {
    cognitiveservices = "privatelink.cognitiveservices.azure.com"
    ai_services       = "privatelink.services.ai.azure.com"
    openai            = "privatelink.openai.azure.com"
  }
  data_dns_zones = {
    cosmos = "privatelink.documents.azure.com"
    search = "privatelink.search.windows.net"
    blob   = "privatelink.blob.core.windows.net"
  }
  private_dns_zones = merge(
    var.foundry_public_network_access ? {} : local.base_dns_zones,
    var.byo_data ? local.data_dns_zones : {},
  )

  # Private DNS zone IDs used by the private endpoints.
  dns_zone_ids = var.create_network ? { for k, z in azurerm_private_dns_zone.plz : k => z.id } : var.private_dns_zone_ids
}

########################################################################
# Virtual network + subnets (created only when create_network = true)
########################################################################

resource "azurerm_virtual_network" "vnet" {
  count = var.create_network ? 1 : 0

  name                = "vnet-agents"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.virtual_network_address_space]
}

# Agent subnet: delegated to Microsoft.App/environments for Foundry agent
# VNet injection (agent egress via the single-tenant data proxy).
resource "azurerm_subnet" "subnet_agent" {
  count = var.create_network ? 1 : 0

  name                 = "snet-agent"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet[0].name
  address_prefixes     = [var.agent_subnet_address_prefix]

  delegation {
    name = "Microsoft.App/environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Private endpoint subnet for Storage / Cosmos / Search / Foundry.
resource "azurerm_subnet" "subnet_pe" {
  count = var.create_network ? 1 : 0

  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet[0].name
  address_prefixes     = [var.private_endpoint_subnet_address_prefix]
}

# Dedicated subnet for the MCP Container Apps (workload-profiles) environment.
# Delegated to Microsoft.App/environments, as required for the environment.
resource "azurerm_subnet" "subnet_aca" {
  count = var.create_network ? 1 : 0

  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet[0].name
  address_prefixes     = [var.aca_subnet_address_prefix]

  delegation {
    name = "Microsoft.App/environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

########################################################################
# Private DNS zones + VNet links (created only when create_network = true)
########################################################################

resource "azurerm_private_dns_zone" "plz" {
  for_each = var.create_network ? local.private_dns_zones : {}

  name                = each.value
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "plz" {
  for_each = var.create_network ? local.private_dns_zones : {}

  name                  = "${each.key}-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.plz[each.key].name
  virtual_network_id    = azurerm_virtual_network.vnet[0].id
  registration_enabled  = false
}
