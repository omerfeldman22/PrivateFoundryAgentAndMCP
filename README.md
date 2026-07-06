# Private Microsoft Foundry Agent + Azure MCP Server

Terraform Infrastructure-as-Code that provisions a **network-secured Microsoft
Foundry agent environment** together with a **private Azure MCP Server** hosted
on Azure Container Apps, so a Foundry agent can invoke Azure operations through
MCP without any traffic leaving your virtual network.

> [!IMPORTANT]
> **This is a reference implementation.** It is intended to demonstrate a
> working pattern and to accelerate experimentation. It is **not** a
> production-hardened product. Before using any part of it in production,
> review the code, understand every resource and its security/cost
> implications, and adapt it to your organization's requirements. **You are
> solely responsible for what you deploy.** Provided "as is", without warranty
> of any kind.

---

## What this project provides

- A **Microsoft Foundry** account (Cognitive Services / `AIServices`) with
  **agent VNet injection** — agent/data-proxy egress flows through a delegated
  subnet in your VNet.
- A configurable model deployment (default **gpt-5**) and a Foundry **project**
  with the required capability host(s).
- An **Azure MCP Server** (`mcr.microsoft.com/azure-sdk/azure-mcp`) on Azure
  Container Apps with **internal (VNet-only) ingress**, authenticated inbound
  via Microsoft Entra, and outbound to Azure via its **managed identity**.
- An optional **example**: an `Azure-MCP-Server` project connection, an MCP
  tool, and a **prompt agent** (`mcp-example`) wired to the MCP server.
- Private endpoints, Private DNS zones, and least-privilege role assignments to
  keep everything private and Entra-authenticated by default.

## Architecture (high level)

```
                    client / developer
                           │  (Foundry endpoint — private or public ingress)
                           ▼
        ┌─────────────────────────────────────────────────────────┐
        │  Microsoft Foundry account + Project + Prompt agent       │
        └───────────────┬───────────────────────────────┬──────────┘
                        │ agent egress (VNet injection)  │ MCP tool call
                        ▼                                ▼
 ┌───────────────────────── Virtual Network ──────────────────────────────┐
 │                                                                         │
 │  snet-agent (delegated          snet-aca                 snet-pe        │
 │  Microsoft.App/environments)    ┌───────────────────┐    ┌───────────┐  │
 │  ┌───────────────────┐          │ Container Apps env │    │ Private   │  │
 │  │ single-tenant     │  MCP     │ (internal LB)      │    │ Endpoints:│  │
 │  │ data proxy        │─────────▶│  Azure MCP Server  │    │ Foundry   │  │
 │  └───────────────────┘          └─────────┬─────────┘    │ Storage*  │  │
 │                                            │ managed id   │ Cosmos*   │  │
 │                                            ▼              │ Search*   │  │
 │                                   Azure ARM (MCP tools)   └───────────┘  │
 │                                                        * only when       │
 │                                                          byo_data = true │
 └─────────────────────────────────────────────────────────────────────────┘
```

## Configurable setups

The same code supports several topologies through a few variables:

| Variable | Values | What it changes |
|---|---|---|
| `byo_data` | `true` (Standard, default) / `false` (Basic) | **Standard** creates and connects your own **Storage + Cosmos DB + AI Search** (end-to-end data isolation, account + project capability hosts wired to the connections). **Basic** uses **platform-managed** data — no Storage/Cosmos/Search are created. |
| `create_network` | `true` (default) / `false` (BYO) | **`true`** creates the VNet, subnets and Private DNS zones. **`false`** consumes a **pre-existing** VNet/subnets/DNS zones you supply by resource ID (landing-zone / hub-spoke friendly). |
| `foundry_public_network_access` | `false` (default) / `true` | **Foundry inbound**: `false` = private ingress via a private endpoint (public access disabled); `true` = public ingress (no private endpoint). **Egress is always private** via VNet injection either way. |
| `create_example_agent` | `true` (default) / `false` | Whether to create the sample MCP project connection, MCP tool, and `mcp-example` prompt agent. |

Common combinations:

- **Fully private, standard data** — `byo_data=true`, `create_network=true`, `foundry_public_network_access=false`.
- **Quick demo** — `byo_data=false`, `foundry_public_network_access=true` (fewer resources, public Foundry endpoint, MCP still private in the VNet).
- **Landing zone** — `create_network=false` with BYO VNet/subnets and a separate `subscription_id_infra` for shared Private DNS zones.

## Repository layout

```
iac/infra/
├── main.tf            # resource group + azurerm_client_config
├── providers.tf       # azurerm / azapi / azuread / random / time
├── versions.tf        # provider + Terraform version constraints
├── variables.tf       # all inputs
├── network.tf         # VNet, subnets, Private DNS zones (for_each) — conditional
├── storage.tf         # Storage account + PE + roles (byo_data)
├── cosmos.tf          # Cosmos DB + PE + roles (byo_data)
├── search.tf          # AI Search + PE + roles (byo_data)
├── foundry.tf         # Foundry account, model, project, connections, capability hosts, PE
├── monitoring.tf      # Log Analytics + Application Insights (optional)
├── mcp.tf             # Container Apps env + MCP app, Entra app, DNS, RBAC
├── agent.tf           # MCP project connection + example prompt agent (data-plane)
├── outputs.tf         # foundry_portal_url (+ external data source)
└── terraform.tfvars.example
```

## Prerequisites

- **Terraform ≥ 1.11.4**.
- **Azure CLI (`az`)**, authenticated (`az login`).
- **`curl`** and **`python3`** on the machine running Terraform — used to
  create the example agent via the Foundry data-plane API and to build the
  Foundry portal URL output.
- **Unix-like shell** (macOS/Linux, or **WSL / Git Bash** on Windows): the
  `local-exec` provisioners and the portal-URL helper use `bash` and
  `python3`, so they don't run under native Windows `cmd`/PowerShell.
- Azure permissions on the workload subscription: `Owner` or
  (`Role Based Access Control Administrator` + `Contributor`), plus the
  **Foundry Account Owner** role.
- **Microsoft Graph** permissions to create an app registration (the MCP Entra
  app and its app-role assignment).
- Registered resource providers: `Microsoft.CognitiveServices`,
  `Microsoft.Storage`, `Microsoft.Search`, `Microsoft.DocumentDB`,
  `Microsoft.Network`, `Microsoft.App`, `Microsoft.OperationalInsights`,
  `Microsoft.Insights`.

## Quick start

```bash
cd iac/infra
cp terraform.tfvars.example terraform.tfvars   # edit values

terraform init
terraform apply -var-file="terraform.tfvars"
```

## Outputs

| Output | Description |
|---|---|
| `foundry_portal_url` | Direct link to the `mcp-example` agent in the Microsoft Foundry portal. |

## The example agent & MCP tool

When `create_example_agent = true`, the deployment also creates:

1. **Project connection** `Azure-MCP-Server` (`RemoteTool`, `custom_MCP`) that
   points at the MCP server's `/sse` endpoint and authenticates with the
   **Foundry project managed identity** (audience = the MCP Entra app client ID).
2. **Prompt agent** `mcp-example` (default model **gpt-5**) with an **MCP tool**
   bound to that connection and instructions that include your tenant and
   subscription IDs.

Because the MCP endpoint is internal to the VNet, the agent reaches it through
the Foundry data proxy in the delegated subnet, resolving it via the Container
Apps environment Private DNS zone created by this template.

Open the agent with `terraform output foundry_portal_url` and try a prompt such
as:

> What resource groups exists in my environment?

## Cleanup

```bash
terraform destroy -var-file="terraform.tfvars"
```

> [!NOTE]
> Destroy purges the Foundry account and waits ~15 minutes so the agent
> subnet's service-association link is released before the subnet/VNet is
> removed. This is required before the delegated subnet can be reused.

## References

- [Foundry Agent Service private networking](https://learn.microsoft.com/azure/ai-foundry/agents/how-to/virtual-networks)
- [Deep dive into Foundry Agent Service networking](https://learn.microsoft.com/azure/ai-foundry/agents/concepts/networking-deep-dive)
- [Connect to MCP server endpoints for agents](https://learn.microsoft.com/azure/ai-foundry/agents/how-to/tools/model-context-protocol)
- [azmcp-foundry-aca-mi sample](https://github.com/Azure-Samples/azmcp-foundry-aca-mi)
- [microsoft-foundry/foundry-samples (Terraform)](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-terraform)

## License

Licensed under the [MIT License](LICENSE) — provided "as is", without warranty
of any kind. See the disclaimer at the top of this document.
