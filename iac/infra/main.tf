data "azurerm_client_config" "current" {}

# Resource group: created by default (rg-<name_prefix>), or reuse a
# pre-existing one (e.g. the RG that holds the BYO VNet) when
# existing_resource_group_name is set.
resource "azurerm_resource_group" "rg" {
  count = var.existing_resource_group_name == "" ? 1 : 0

  name     = "rg-${var.name_prefix}"
  location = var.location
}

data "azurerm_resource_group" "existing" {
  count = var.existing_resource_group_name == "" ? 0 : 1

  name = var.existing_resource_group_name
}

locals {
  rg_name = var.existing_resource_group_name == "" ? azurerm_resource_group.rg[0].name : data.azurerm_resource_group.existing[0].name
  rg_id   = var.existing_resource_group_name == "" ? azurerm_resource_group.rg[0].id : data.azurerm_resource_group.existing[0].id
}