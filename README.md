# repo-baseline

A minimal GitHub template repository providing baseline structure and conventions for new projects.

## What This Is

This is a **template repository** that provides:
- Contribution guidelines ([CONTRIBUTING.md](CONTRIBUTING.md)) and AI collaboration guidance ([AGENTS.md](AGENTS.md))
- Issue and pull request templates for structured communication
- Manual Azure OIDC validation workflow
- A starting point that avoids premature technical decisions

This template is intentionally minimal and public-safe, containing no secrets, licenses, or environment-specific configuration.

## How to Use as a Template

1. Click the **"Use this template"** button on GitHub
2. Create a new repository from this template (public or private)
3. Follow the post-creation checklist below

## Post-Creation Checklist

After creating a repository from this template:

- [ ] **Choose and add a LICENSE file** - This template intentionally omits a license; add one appropriate for your project
- [ ] **Configure Azure OIDC** (if using Azure) - Set up federated credentials and add the following repository secrets:
  - `AZURE_CLIENT_ID` (repository variable)
  - `AZURE_TENANT_ID` (repository secret)
  - `AZURE_SUBSCRIPTION_ID` (repository secret)
  
  See [docs/azure-oidc-setup.md](docs/azure-oidc-setup.md) for detailed setup instructions. Then run the "Azure OIDC Connectivity Check" workflow manually to verify the configuration.
- [ ] **Enable AI agent Azure access** (if using Azure with Copilot coding agent) - Run `azd coding-agent config` to give AI agents read-time visibility into Azure state while authoring changes. See [docs/azure-coding-agent-guide.md](docs/azure-coding-agent-guide.md) for guidance.
- [ ] **Update README.md** - Replace this generic template README with repository-specific documentation
- [ ] **Review AGENTS.md** - Update or remove this file to reflect your repository's specific purpose and conventions