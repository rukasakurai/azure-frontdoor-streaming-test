# Contributing

Thank you for your interest in contributing to this project. This document is the canonical source of contribution guidelines and applies to **all contributors**—whether working manually or through automated tooling.

## Collaboration & Decision-Making Style

- **Start lean**: Prefer minimal, focused implementations over comprehensive solutions
- **Minimize changes**: Make the smallest possible modifications to achieve the goal
- **Defer specifics**: Avoid hardcoding environment-specific values (tenant IDs, subscription IDs, secrets)
- **Public-safe by default**: Never suggest or add sensitive information (secrets, Azure IDs, API keys)
- **Template-first thinking**: Any addition should be generally useful across multiple derived repositories
- **Respect deferred decisions**: Do not add licenses, specific deployment configurations, or technology-specific scaffolding unless explicitly requested
- **Validate assumptions**: When working on derived repositories, check if baseline conventions are still relevant before applying them

## Constraints & Assumptions

- **No license file**: License choice is intentionally deferred to derived repositories
- **No automatic CI/CD**: Continuous integration and deployment patterns vary by project
- **No secrets or identifiers**: All Azure/cloud credentials must be configured per repository
- **No technology assumptions**: No language-specific tooling, frameworks, or build systems
