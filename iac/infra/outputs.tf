# The Foundry portal encodes the subscription ID as base64url of its GUID
# bytes; compute it with a small helper so the portal link is generic.
data "external" "foundry_portal_url" {
  program = ["python3", "${path.module}/scripts/foundry_portal_url.py"]

  query = {
    subscription_id = data.azurerm_client_config.current.subscription_id
    resource_group  = azurerm_resource_group.rg.name
    account         = local.foundry_name
    project         = local.project_name
    agent           = var.agent_name
  }
}

output "foundry_portal_url" {
  description = "Direct link to the agent in the Microsoft Foundry portal."
  value       = data.external.foundry_portal_url.result.url
}
