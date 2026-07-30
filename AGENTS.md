# AGENTS.md

> **Canonical contribution guidelines live in [CONTRIBUTING.md](CONTRIBUTING.md).**
> This file adds only agent/tool-operational context. All general collaboration rules, constraints, and assumptions defined there apply here as well.

## Repository Purpose

This repository is a **test harness for Azure Front Door (Premium) behaviour**. Its primary question is whether AFD buffers or passes through streaming HTTP responses (SSE and NDJSON); it also carries a secondary set of scripts probing AFD caching behaviour, which reuse the same deployment. See the [README](README.md) for the full picture.

## Azure Access

The [Azure Developer CLI Copilot Coding Agent Extension](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/extensions/copilot-coding-agent-extension) can give agents read-time visibility into Azure state while authoring changes. See [docs/azure-coding-agent-guide.md](docs/azure-coding-agent-guide.md) for guidance.