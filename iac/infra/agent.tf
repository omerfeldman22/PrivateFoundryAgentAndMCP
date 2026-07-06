########################################################################
# Example: MCP project connection + "mcp-example" prompt agent
#
# Foundry agents have no ARM/azapi resource type — they live on the data
# plane — so the agent is created via the Foundry REST API using az CLI.
# The MCP project connection IS an ARM resource, so it uses azapi.
########################################################################

locals {
  # Foundry project data-plane endpoint.
  project_endpoint = "https://${local.foundry_name}.services.ai.azure.com/api/projects/${local.project_name}"

  # The Azure MCP server is served at the /sse path on the container app.
  mcp_server_url = "https://${azurerm_container_app.mcp.ingress[0].fqdn}/sse"

  agent_instructions = "You are connected to an MCP tool/server that can invoke commands against Azure\n\nTenant ID: ${data.azurerm_client_config.current.tenant_id}\nSubscription ID: ${data.azurerm_client_config.current.subscription_id}"

  agent_body = {
    name        = var.agent_name
    description = "Prompt agent connected to the Azure MCP server."
    definition = {
      kind         = "prompt"
      model        = try(var.model_deployment[0].name, "gpt-5")
      instructions = local.agent_instructions
      tools = [
        {
          type                  = "mcp"
          server_label          = var.mcp_connection_name
          server_url            = local.mcp_server_url
          project_connection_id = var.mcp_connection_name
        }
      ]
    }
  }

  agent_body_json = jsonencode(local.agent_body)
}

# Project connection to the private MCP server, using the Foundry project
# managed identity to authenticate (audience = the MCP Entra app client ID).
resource "azapi_resource" "conn_mcp" {
  count = var.create_example_agent ? 1 : 0

  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name                      = var.mcp_connection_name
  parent_id                 = azapi_resource.ai_foundry_project.id
  schema_validation_enabled = false

  body = {
    properties = {
      category                    = "RemoteTool"
      target                      = local.mcp_server_url
      authType                    = "ProjectManagedIdentity"
      audience                    = azuread_application.mcp.client_id
      group                       = "GenericProtocol"
      isSharedToAll               = false
      useWorkspaceManagedIdentity = false
      metadata = {
        type = "custom_MCP"
      }
    }
  }

  depends_on = [azapi_resource.ai_foundry_project]
}

# Prompt agent created through the Foundry data-plane REST API. Re-created
# whenever the endpoint, name or definition changes.
resource "terraform_data" "mcp_agent" {
  count = var.create_example_agent ? 1 : 0

  triggers_replace = {
    project_endpoint = local.project_endpoint
    agent_name       = var.agent_name
    definition       = local.agent_body_json
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      AGENT_BODY = local.agent_body_json
    }
    command = <<-EOT
      set -euo pipefail
      TOKEN=$(az account get-access-token --scope "https://ai.azure.com/.default" --query accessToken -o tsv)
      curl -sS -X POST "${local.project_endpoint}/agents?api-version=v1" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        --data-binary "$AGENT_BODY"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      TOKEN=$(az account get-access-token --scope "https://ai.azure.com/.default" --query accessToken -o tsv)
      curl -sS -X DELETE "${self.triggers_replace.project_endpoint}/agents/${self.triggers_replace.agent_name}?api-version=v1" \
        -H "Authorization: Bearer $TOKEN" || true
    EOT
  }

  depends_on = [
    azapi_resource.conn_mcp,
    azapi_resource.ai_foundry_project_capability_host,
    azurerm_container_app.mcp,
  ]
}
