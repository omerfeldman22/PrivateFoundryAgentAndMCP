provider "azurerm" {
  # ARM_SUBSCRIPTION_ID must be set, or set subscription_id below.
  subscription_id = var.subscription_id != "" ? var.subscription_id : null

  features {
    cognitive_account {
      # Purge the Foundry (Cognitive Services) account on destroy so the
      # agent subnet's service association link is released for reuse.
      purge_soft_delete_on_destroy = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azapi" {}

provider "azuread" {}

provider "random" {}

provider "time" {}

# Aliased provider for a separate subscription that holds pre-existing
# Private DNS zones (BYO / landing-zone). Use with `provider = azurerm.infra`
# on DNS resources when create_network = false and DNS lives in another sub.
provider "azurerm" {
  alias           = "infra"
  subscription_id = var.subscription_id_infra != "" ? var.subscription_id_infra : (var.subscription_id != "" ? var.subscription_id : null)

  features {}
}
