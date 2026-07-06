########################################################################
# Core / subscription
########################################################################

variable "subscription_id" {
  description = "Subscription ID where the Foundry + MCP resources are deployed. Leave empty to use ARM_SUBSCRIPTION_ID."
  type        = string
}

variable "location" {
  description = "Azure region for all resources. Must match the region of the (BYO or created) virtual network."
  type        = string
  default     = "swedencentral"
}

variable "name_prefix" {
  description = "Lowercase alphanumeric prefix used when composing resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.name_prefix))
    error_message = "name_prefix must be 2-10 lowercase letters/numbers."
  }
}

########################################################################
# Foundry agent setup
########################################################################

variable "byo_data" {
  description = "If true (Standard setup), create and connect BYO data resources (Storage, Cosmos DB, AI Search) for end-to-end isolation. If false (Basic setup), use platform-managed data — no Storage/Cosmos/Search are created."
  type        = bool
  default     = true
}

variable "foundry_public_network_access" {
  description = "Controls INBOUND access to the Foundry account. false (default) = private ingress via a private endpoint (public access disabled). true = public ingress over the account's public endpoint (no private endpoint created). Egress is always private via VNet injection."
  type        = bool
  default     = false
}

variable "create_example_agent" {
  description = "If true, create the example MCP project connection and the 'mcp-example' prompt agent. The agent is created via the Foundry data-plane REST API, so the machine running Terraform needs the Azure CLI (az) and curl."
  type        = bool
  default     = true
}

variable "agent_name" {
  description = "Name of the example prompt agent."
  type        = string
  default     = "mcp-example"
}

variable "mcp_connection_name" {
  description = "Name of the Foundry project connection to the MCP server."
  type        = string
  default     = "Azure-MCP-Server"
}

########################################################################
# Network toggle (create vs BYO)
########################################################################

variable "create_network" {
  description = "If true, create the VNet, subnets and Private DNS zones. If false, consume pre-existing resources via the *_id variables below."
  type        = bool
  default     = true
}

# ---- Used when create_network = true ------------------------------------

variable "virtual_network_address_space" {
  description = "Address space of the VNet to create. Must be an RFC1918 range."
  type        = string
  default     = "192.168.0.0/16"
}

variable "agent_subnet_address_prefix" {
  description = "CIDR for the agent (delegated) subnet. /24 recommended for production."
  type        = string
  default     = "192.168.0.0/24"
}

variable "private_endpoint_subnet_address_prefix" {
  description = "CIDR for the private endpoint subnet."
  type        = string
  default     = "192.168.1.0/24"
}

variable "aca_subnet_address_prefix" {
  description = "CIDR for the MCP Container Apps environment subnet. /27 minimum for workload-profiles environments."
  type        = string
  default     = "192.168.2.0/27"
}

# ---- Used when create_network = false (BYO) ------------------------------

variable "subscription_id_infra" {
  description = "Subscription ID holding pre-existing Private DNS zones (BYO / landing-zone). Only used when create_network = false. Defaults to the resources subscription when empty."
  type        = string
  default     = ""
}

variable "subnet_id_agent" {
  description = "Resource ID of the pre-existing subnet delegated to Microsoft.App/environments for the Foundry agent. Required when create_network = false."
  type        = string
  default     = ""
}

variable "subnet_id_private_endpoint" {
  description = "Resource ID of the pre-existing subnet for private endpoints. Required when create_network = false."
  type        = string
  default     = ""
}

variable "subnet_id_aca" {
  description = "Resource ID of the pre-existing subnet for the MCP Container Apps environment. Required when create_network = false."
  type        = string
  default     = ""
}

variable "vnet_id" {
  description = "Resource ID of the VNet to link the ACA-environment Private DNS zone to (so the Foundry data proxy can resolve the internal MCP endpoint). Required when create_network = false."
  type        = string
  default     = ""
}

variable "private_dns_zone_ids" {
  description = "Map of pre-existing Private DNS zone resource IDs when create_network = false. Keys: cognitiveservices, openai, ai_services, blob, search, cosmos."
  type = object({
    cognitiveservices = string
    openai            = string
    ai_services       = string
    blob              = string
    search            = string
    cosmos            = string
  })
  default = null
}

########################################################################
# Foundry model deployment
########################################################################

variable "model_deployment" {
  description = "Model deployment(s) for the Foundry account."
  type = list(object({
    name         = string # deployment name
    format       = string # model publisher/format
    model_name   = string # model name
    version      = string # model version
    sku_name     = string # deployment SKU (e.g. GlobalStandard)
    sku_capacity = number # deployment capacity (units of 1,000 TPM)
  }))
  default = [{
    name         = "gpt-5"
    format       = "OpenAI"
    model_name   = "gpt-5"
    version      = "2025-08-07"
    sku_name     = "GlobalStandard"
    sku_capacity = 10
  }]
}

########################################################################
# Azure MCP Server on Container Apps
########################################################################

variable "mcp_namespaces" {
  description = "Optional list of Azure MCP tool namespaces to enable (max 3). Empty = all namespaces (--mode all with no --namespace flag). for namespace options, please refer to the documentation: https://learn.microsoft.com/en-us/azure/developer/azure-mcp-server/tools/#available-tools"
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.mcp_namespaces) <= 3
    error_message = "You can specify at most 3 MCP namespaces."
  }
}

variable "mcp_read_only" {
  description = "If true, start the MCP server with --read-only so only read tools are exposed."
  type        = bool
  default     = true
}

variable "mcp_grant_rg_reader" {
  description = "If true, grant the MCP managed identity the Reader role on the deployment resource group (read-only baseline for tool calls)."
  type        = bool
  default     = true
}

variable "enable_application_insights" {
  description = "If true, deploy Log Analytics + Application Insights and wire the MCP server telemetry to it."
  type        = bool
  default     = true
}

variable "entra_app_display_name" {
  description = "Display name for the Entra application used for incoming OAuth auth to the MCP server."
  type        = string
  default     = "azure-mcp-server"
}
