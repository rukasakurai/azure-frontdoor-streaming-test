# Azure Coding Agent Guide

This guide supplements the [official Azure Developer CLI documentation](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/extensions/copilot-coding-agent-extension) with additional context for deciding when and how to set up GitHub Copilot coding agent with Azure access.

For the core setup steps, see the official documentation. This guide covers:

- [When to Use This](#when-to-use-this) — decision guidance for whether this setup adds value
- [Key Benefits Over CI-Only Validation](#key-benefits-over-ci-only-validation) — why read-time Azure access matters
- [Choosing a Resource Group and Managed Identity](#choosing-a-resource-group-and-managed-identity) — guidance based on your existing `azd` environment setup
- [Customizing the Copilot Setup Steps Workflow](#customizing-the-copilot-setup-steps-workflow) — what can and cannot be changed
- [Supply-Chain Considerations](#supply-chain-considerations) — version pinning for `@azure/mcp`
- [Caveats and Limitations](#caveats-and-limitations) — setting realistic expectations

> **Note**: Some topics in this guide may be incorporated into the [official documentation](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/extensions/copilot-coding-agent-extension) in the future. Check the official docs first for the most current information.

## When to Use This

> **Note**: This decision guidance is not currently in the official docs. It may be added in the future as the extension matures.

**Add this setup** when a repository:
- Deploys or manages Azure resources and frequently encounters Azure-specific unknowns during IaC authoring
- Benefits from the agent having least-privilege Azure visibility (Reader scoped to a resource group)

**Skip or keep optional** when:
- The repository does not deploy Azure resources
- You do not want automated identity/bootstrap changes (resource group, managed identity, federation) as part of standard repo initialization

## Key Benefits Over CI-Only Validation

> **Note**: This value-proposition framing is not currently in the official docs. The [Azure SDK blog post](https://devblogs.microsoft.com/azure-sdk/azure-developer-cli-copilot-coding-agent-config/) provides some context.

CI/CD workflows (such as this repository's [Azure OIDC connectivity check](../.github/workflows/azure-oidc-check.yml)) can automate `azd provision` on PRs, giving post-hoc validation of infrastructure changes. However, that approach validates changes **after the fact** — the agent authors a change, CI runs, and failures surface only then.

The coding agent extension complements CI-based validation by giving the agent **read-time visibility into Azure state while it is authoring changes**:

1. **Fewer iteration loops** — The agent can confirm what exists in the target resource group (names, types, regions, SKUs) *before* proposing IaC changes, reducing "guess → fail CI → revise" cycles
2. **Better failure triage** — When `azd up` fails in CI, the agent can correlate log errors with actual Azure-side state to propose more accurate fixes
3. **Consistent setup across repos** — For template-derived repositories, the extension automates the repetitive parts (managed identity, federated credentials, environment config) so each new repo starts agent-ready
4. **Controlled scope** — Default Reader role follows least-privilege; additional roles (e.g., Contributor) can be granted per-repo as needed

## Choosing a Resource Group and Managed Identity

> **Note**: This guidance on resource group selection based on existing `azd` environments is not currently in the official docs. It may be added in the future.

The `azd coding-agent config` command asks you to select or create a **resource group** (where the managed identity is placed) and scopes the default **Reader** role to that resource group.

### The core decision

You have two options:

**Option A: Use a dedicated agent resource group**

Create a resource group solely for the managed identity (e.g., `rg-copilot-agent`). This keeps identity resources separate from application resources and decouples the identity's lifecycle from any single environment.

Benefits:
- **Cross-repo sharing**: The extension prompts "Create new user-assigned managed identity" or "Use existing user-assigned managed identity" — you can reuse the same identity across multiple repositories by selecting "Use existing" and adding a federated credential for each repo
- **Lifecycle stability**: If application resource groups are torn down (e.g., ephemeral dev environments), the identity persists
- **Centralized management**: One identity with role assignments to multiple resource groups

Trade-offs:
- Requires granting Reader on each application resource group the agent should inspect:
  ```bash
  az role assignment create \
    --assignee <managed-identity-client-id> \
    --role Reader \
    --scope /subscriptions/<sub-id>/resourceGroups/<app-resource-group>
  ```
- If the shared identity's permissions are misconfigured, all repos using it are affected

Cross-subscription and cross-tenant considerations:
- **Same Entra tenant, different subscription**: Supported. A managed identity can be granted roles on resource groups in any subscription within the same Entra tenant — just use the target subscription's ID in the `--scope` parameter
- **Different Entra tenant**: Not directly supported. Azure RBAC requires the principal to be resolvable in the same tenant as the resources, so a managed identity from Tenant A cannot be directly granted roles in Tenant B. Cross-tenant implementation maybe possible but would require a different architectural pattern

**Option B: Use an application resource group**

Place the managed identity in a resource group your application uses (or will use). The agent gets immediate Reader visibility into that environment.

- If you already have `azd` environments, check which resource groups exist:
  ```bash
  azd env list
  azd env get-value AZURE_RESOURCE_GROUP --environment <env-name>
  ```
- If you have multiple environments, choose one the agent will commonly need to inspect
- If you have no environments yet, create the resource group now (e.g., `rg-<app>-dev`) — when you later run `azd provision` targeting this RG, the agent already has visibility

Trade-off: If the resource group is torn down (e.g., ephemeral environments), the managed identity is deleted and you'll need to reconfigure.

### Granting access to additional resource groups

Whichever option you choose, you can grant Reader access to additional resource groups as needed:

```bash
az role assignment create \
  --assignee <managed-identity-client-id> \
  --role Reader \
  --scope /subscriptions/<sub-id>/resourceGroups/<other-resource-group>
```

> **Least-privilege tip**: Avoid granting Reader to production resource groups unless the agent specifically needs to inspect production state.

## Customizing the Copilot Setup Steps Workflow

> **Note**: The official azd docs briefly mention the workflow file. For detailed customization options, see the [GitHub documentation on customizing the Copilot coding agent environment](https://docs.github.com/en/copilot/customizing-copilot/customizing-the-development-environment-for-copilot-coding-agent). This section summarizes key constraints.

The `azd coding-agent config` command generates `.github/workflows/copilot-setup-steps.yml`. This workflow runs automatically before each Copilot coding agent session. It is **not** triggered through normal GitHub Actions event mechanisms — the Copilot coding agent finds and invokes it directly by its well-known path and job name.

### What cannot be changed

- **File path**: Must be exactly `.github/workflows/copilot-setup-steps.yml`
- **Job name**: Must be exactly `copilot-setup-steps`

### What can be changed

Within the `copilot-setup-steps` job, you can customize:

| Setting | Notes |
|---|---|
| `steps` | Add, remove, or modify setup steps |
| `permissions` | Scope to least privilege |
| `runs-on` | Larger runners or ARC self-hosted runners (Ubuntu x64 only) |
| `services` | Add service containers |
| `timeout-minutes` | Maximum: 59 |
| `environment` | The generated file uses `copilot` to pull in Azure variables |

### Trigger configuration

The `on:` trigger does not affect how the Copilot coding agent invokes the workflow. However, triggers are useful for **validating the workflow itself**:

```yaml
on:
  workflow_dispatch:
  push:
    paths:
      - .github/workflows/copilot-setup-steps.yml
  pull_request:
    paths:
      - .github/workflows/copilot-setup-steps.yml
```

## Supply-Chain Considerations

> **Note**: This is not currently mentioned in the official docs.

The default MCP server configuration uses `@azure/mcp@latest`:

```json
{
  "mcpServers": {
    "Azure": {
      "type": "local",
      "command": "npx",
      "args": ["-y", "@azure/mcp@latest", "server", "start"],
      "tools": ["*"]
    }
  }
}
```

For reproducibility and supply-chain hygiene, consider pinning to a specific version (e.g., `@azure/mcp@0.1.0`) rather than using `latest`.

## Caveats and Limitations

> **Note**: These caveats are not currently in the official docs.

- **Manual steps still required**: The extension automates Azure-side and GitHub environment setup, but you must still manually merge the generated PR, paste the MCP config into repository settings, and optionally adjust roles beyond Reader
- **Agent behavior is not guaranteed**: Whether the agent consistently uses MCP tools correctly or produces better outcomes depends on the task complexity and model behavior — results may vary
- **Azure-specific**: This setup provides little to no benefit for repositories that do not interact with Azure resources
- **Complements, does not replace, CI validation**: This gives the agent read-time Azure visibility; you should still run `azd provision`/`azd up` in CI (e.g., via the [OIDC check workflow](../.github/workflows/azure-oidc-check.yml)) for authoritative deployment validation

## Additional Resources

- **Official Setup Guide**: [Connect GitHub Copilot coding agent with Azure MCP Server using azd](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/extensions/copilot-coding-agent-extension)
- **Azure SDK Blog**: [Introducing the azd extension to configure GitHub Copilot coding agent](https://devblogs.microsoft.com/azure-sdk/azure-developer-cli-copilot-coding-agent-config/)
- **GitHub Documentation**: [Customizing the development environment for Copilot coding agent](https://docs.github.com/en/copilot/customizing-copilot/customizing-the-development-environment-for-copilot-coding-agent)
- **Azure OIDC Setup**: See [azure-oidc-setup.md](azure-oidc-setup.md) for foundational Azure OIDC configuration
