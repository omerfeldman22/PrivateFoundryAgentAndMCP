terraform {
  required_version = ">= 1.11.4"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.53"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.7"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
