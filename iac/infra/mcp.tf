########################################################################
# Entra application for incoming OAuth auth to the MCP server
########################################################################

resource "random_uuid" "mcp_app_role" {}

resource "azuread_application" "mcp" {
  display_name                   = "${var.name_prefix}-${var.entra_app_display_name}"
  prevent_duplicate_names        = true
  fallback_public_client_enabled = false

  # Issue v2 access tokens — required for the Foundry project MI to acquire a
  # token for this app (v1 causes "ARA request failed / BadRequest").
  api {
    requested_access_token_version = 2
  }

  app_role {
    allowed_member_types = ["Application"]
    description          = "Allows callers to invoke MCP tools on the Azure MCP Server."
    display_name         = "Mcp.Tools.ReadWrite.All"
    enabled              = true
    id                   = random_uuid.mcp_app_role.result
    value                = "Mcp.Tools.ReadWrite.All"
  }

  # identifier_uris is managed by azuread_application_identifier_uri below;
  # ignore it here to avoid a perpetual remove/re-add diff.
  lifecycle {
    ignore_changes = [identifier_uris]
  }
}

# Set the identifier URI to api://<clientId> (separate resource avoids a
# self-reference cycle on the application's own client_id).
resource "azuread_application_identifier_uri" "mcp" {
  application_id = azuread_application.mcp.id
  identifier_uri = "api://${azuread_application.mcp.client_id}"
}

resource "azuread_service_principal" "mcp" {
  client_id = azuread_application.mcp.client_id
}

# Grant the Foundry project managed identity the MCP app role so it can call
# the MCP server (Microsoft Entra -> Project Managed Identity auth).
resource "azuread_app_role_assignment" "foundry_project_mcp" {
  app_role_id         = random_uuid.mcp_app_role.result
  principal_object_id = local.project_principal_id
  resource_object_id  = azuread_service_principal.mcp.object_id

  depends_on = [time_sleep.wait_project_identities]
}

########################################################################
# MCP server startup arguments
########################################################################

locals {
  mcp_env_name = "${var.name_prefix}-mcp-env"
  mcp_app_name = "${var.name_prefix}-mcp"

  mcp_args = concat(
    ["--transport", "http", "--outgoing-auth-strategy", "UseHostingEnvironmentIdentity", "--mode", "all"],
    var.mcp_read_only ? ["--read-only"] : [],
    flatten([for ns in var.mcp_namespaces : ["--namespace", ns]]),
  )

  mcp_appi_connection_string = var.enable_application_insights ? azurerm_application_insights.appi[0].connection_string : ""
}

########################################################################
# Container Apps environment (internal / VNet-injected)
########################################################################

resource "azurerm_container_app_environment" "mcp" {
  name                           = local.mcp_env_name
  location                       = var.location
  resource_group_name            = local.rg_name
  infrastructure_subnet_id       = local.aca_subnet_id
  internal_load_balancer_enabled = true
  log_analytics_workspace_id     = var.enable_application_insights ? azurerm_log_analytics_workspace.law[0].id : null

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

########################################################################
# Private DNS for the internal Container Apps environment
#
# The Foundry data proxy (in the delegated agent subnet) resolves the MCP
# server through this zone. The wildcard A record points at the environment's
# internal static IP.
########################################################################

resource "azurerm_private_dns_zone" "aca_env" {
  name                = azurerm_container_app_environment.mcp.default_domain
  resource_group_name = local.rg_name
}

resource "azurerm_private_dns_a_record" "aca_env_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.aca_env.name
  resource_group_name = local.rg_name
  ttl                 = 300
  records             = [azurerm_container_app_environment.mcp.static_ip_address]
}

resource "azurerm_private_dns_zone_virtual_network_link" "aca_env" {
  name                  = "aca-env-link"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.aca_env.name
  virtual_network_id    = local.dns_link_vnet_id
  registration_enabled  = false
}

########################################################################
# Azure MCP Server container app
########################################################################

resource "azurerm_container_app" "mcp" {
  name                         = local.mcp_app_name
  container_app_environment_id = azurerm_container_app_environment.mcp.id
  resource_group_name          = local.rg_name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type = "SystemAssigned"
  }

  ingress {
    # Internal-LB environment, so external_enabled = true exposes the app on
    # that internal load balancer — reachable across the VNet (Foundry data
    # proxy), NOT the internet. false would restrict it to the environment only.
    external_enabled           = true
    target_port                = 8080
    transport                  = "http"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "azure-mcp"
      image  = "mcr.microsoft.com/azure-sdk/azure-mcp:latest"
      cpu    = 0.5
      memory = "1Gi"
      args   = local.mcp_args

      env {
        name  = "ASPNETCORE_ENVIRONMENT"
        value = "Production"
      }
      env {
        name  = "ASPNETCORE_URLS"
        value = "http://+:8080"
      }
      env {
        name  = "AZURE_TOKEN_CREDENTIALS"
        value = "managedidentitycredential"
      }
      env {
        name  = "AZURE_MCP_INCLUDE_PRODUCTION_CREDENTIALS"
        value = "true"
      }
      env {
        name  = "AZURE_MCP_COLLECT_TELEMETRY"
        value = tostring(var.enable_application_insights)
      }
      env {
        name  = "AzureAd__Instance"
        value = "https://login.microsoftonline.com/"
      }
      env {
        name  = "AzureAd__TenantId"
        value = data.azurerm_client_config.current.tenant_id
      }
      env {
        name  = "AzureAd__ClientId"
        value = azuread_application.mcp.client_id
      }
      env {
        name  = "AZURE_LOG_LEVEL"
        value = "Verbose"
      }
      # Ingress terminates TLS at the Envoy proxy; the container listens on
      # plain HTTP inside the pod, so redirection must be disabled.
      env {
        name  = "AZURE_MCP_DANGEROUSLY_DISABLE_HTTPS_REDIRECTION"
        value = "true"
      }
      # Honor X-Forwarded-Proto so OAuth metadata advertises https URLs.
      env {
        name  = "AZURE_MCP_DANGEROUSLY_ENABLE_FORWARDED_HEADERS"
        value = "true"
      }

      dynamic "env" {
        for_each = var.enable_application_insights ? [1] : []
        content {
          name  = "APPLICATIONINSIGHTS_CONNECTION_STRING"
          value = local.mcp_appi_connection_string
        }
      }
    }

    http_scale_rule {
      name                = "http-scaler"
      concurrent_requests = 100
    }
  }

  depends_on = [azuread_application_identifier_uri.mcp]
}

########################################################################
# MCP managed-identity outbound role assignments
########################################################################

resource "azurerm_role_assignment" "mcp_rg_reader" {
  count = var.mcp_grant_rg_reader ? 1 : 0

  scope                = local.rg_id
  role_definition_name = "Reader"
  principal_id         = azurerm_container_app.mcp.identity[0].principal_id
}
