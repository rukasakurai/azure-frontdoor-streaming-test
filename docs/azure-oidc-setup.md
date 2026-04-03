# Azure OIDC Configuration Guide

This guide provides step-by-step instructions for configuring Azure OpenID Connect (OIDC) authentication for GitHub Actions workflows in this repository.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Step 1: Create Microsoft Entra ID (Azure AD) App Registration](#step-1-create-microsoft-entra-id-azure-ad-app-registration)
- [Step 2: Configure Federated Credentials](#step-2-configure-federated-credentials)
- [Step 3: Assign Azure Permissions](#step-3-assign-azure-permissions)
- [Step 4: Configure GitHub Repository Variables and Secrets](#step-4-configure-github-repository-variables-and-secrets)
- [Step 5: Verify Configuration](#step-5-verify-configuration)
- [Troubleshooting](#troubleshooting)
- [Additional Resources](#additional-resources)

## Overview

Azure OIDC allows GitHub Actions workflows to authenticate with Azure without storing long-lived credentials as secrets. Instead, GitHub Actions exchanges a short-lived token with Azure using OpenID Connect, providing enhanced security.

This repository includes a validation workflow (`.github/workflows/azure-oidc-check.yml`) that you can use to verify your OIDC configuration is working correctly.

## Prerequisites

Before you begin, ensure you have:

- **Azure Subscription**: An active Azure subscription where you have appropriate permissions
- **Azure CLI**: Installed locally for running commands ([Install Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)). Verify with `az version`.
- **Azure Permissions**: Ability to create app registrations (Microsoft Entra ID) and assign roles (typically requires Contributor or Owner role)
- **GitHub Repository**: Admin access to the GitHub repository where you want to configure OIDC
- **GitHub Repository Settings**: Ensure your repository has Actions enabled

## Step 1: Create Microsoft Entra ID (Azure AD) App Registration

1. **Sign in to Azure using the Azure CLI** (manual step):
   ```bash
   az login
   ```

   If your organization uses Conditional Access and interactive browser login is blocked, use device code login:
   ```bash
   az login --use-device-code
   ```

   If you have multiple tenants, or your organization requires explicit tenant scoping:
   ```bash
   az login --tenant "<your-tenant-id>"
   ```

   After login, ensure you're targeting the right subscription:
   ```bash
   az account set --subscription "<your-subscription-id>"
   ```

2. **Create a new App Registration**:
   ```bash
   az ad app create --display-name "GitHub-OIDC-YourRepoName"
   ```

   Take note of the `appId` (also called Client ID) from the output, then set it as an environment variable:
   ```bash
   export APP_ID="<your-app-id-from-output>"
   ```

   PowerShell:
   ```powershell
   $env:APP_ID = "<your-app-id-from-output>"
   ```

3. **Create a Service Principal** for the app:
   ```bash
   az ad sp create --id $APP_ID
   ```

   PowerShell:
   ```powershell
   az ad sp create --id $env:APP_ID
   ```

4. **Retrieve your Tenant ID and Subscription ID**:
   ```bash
   # Get Tenant ID
   az account show --query tenantId -o tsv
   
   # Get Subscription ID
   az account show --query id -o tsv
   ```

   Save these values - you'll need them for GitHub Actions variables/secrets configuration.

## Step 2: Configure Federated Credentials

Federated credentials establish the trust relationship between GitHub and Azure.

> Note: The `issuer` value must match GitHub's `iss` claim exactly. GitHub issues tokens with `iss` set to `https://token.actions.githubusercontent.com` (no trailing slash).

1. **Set environment variables** for easier configuration (if continuing from Step 1 in the same terminal session, `APP_ID` should already be set):
   ```bash
   export APP_ID="<your-app-id>"
   export GITHUB_ORG="<your-github-org>"
   export GITHUB_REPO="<your-repo-name>"
   ```

   PowerShell:
   ```powershell
   $env:APP_ID = "<your-app-id>"
   $env:GITHUB_ORG = "<your-github-org>"
   $env:GITHUB_REPO = "<your-repo-name>"
   ```

2. **Create a federated credential** for the main branch:
   ```bash
    # Azure CLI expects the *application object id* for federated-credential operations.
    # (The app's client id is $APP_ID; the object id is a different GUID.)
    APP_OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)

   az ad app federated-credential create \
          --id "$APP_OBJECT_ID" \
     --parameters '{
       "name": "github-federated-credential",
       "issuer": "https://token.actions.githubusercontent.com",
       "subject": "repo:'"$GITHUB_ORG"'/'"$GITHUB_REPO"':ref:refs/heads/main",
       "audiences": ["api://AzureADTokenExchange"]
     }'
   ```

   PowerShell:
   ```powershell
   # Azure CLI expects the *application object id* for federated-credential operations.
   # (The app's client id is $env:APP_ID; the object id is a different GUID.)
   $env:APP_OBJECT_ID = (az ad app show --id $env:APP_ID --query id -o tsv)

   $subject = "repo:$env:GITHUB_ORG/$env:GITHUB_REPO:ref:refs/heads/main"
   $payload = @{
      name      = "github-federated-credential"
      issuer    = "https://token.actions.githubusercontent.com"
      subject   = $subject
      audiences = @("api://AzureADTokenExchange")
   } | ConvertTo-Json -Depth 4

   az ad app federated-credential create --id $env:APP_OBJECT_ID --parameters $payload
   ```

      > Note: If PowerShell JSON quoting causes errors, write `$payload` to a temp file and pass the file path:
      > ```powershell
      > $jsonPath = Join-Path $env:TEMP 'federated-credential.json'
      > $payload | Set-Content -Path $jsonPath -Encoding utf8
      > az ad app federated-credential create --id $env:APP_OBJECT_ID --parameters $jsonPath
      > Remove-Item -Path $jsonPath
      > ```

3. **(Optional) Add federated credentials for other branches or environments**:
   
   For pull requests:
   ```bash
    APP_OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)

   az ad app federated-credential create \
       --id "$APP_OBJECT_ID" \
     --parameters '{
       "name": "github-pr-credential",
       "issuer": "https://token.actions.githubusercontent.com",
       "subject": "repo:'"$GITHUB_ORG"'/'"$GITHUB_REPO"':pull_request",
       "audiences": ["api://AzureADTokenExchange"]
     }'
   ```

    PowerShell:
    ```powershell
    $subject = "repo:$env:GITHUB_ORG/$env:GITHUB_REPO:pull_request"
    $payload = @{
       name      = "github-pr-credential"
       issuer    = "https://token.actions.githubusercontent.com"
       subject   = $subject
       audiences = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Depth 4

      az ad app federated-credential create --id $env:APP_OBJECT_ID --parameters $payload
    ```

   For specific environments:
   ```bash
    APP_OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)

   az ad app federated-credential create \
       --id "$APP_OBJECT_ID" \
     --parameters '{
       "name": "github-env-credential",
       "issuer": "https://token.actions.githubusercontent.com",
       "subject": "repo:'"$GITHUB_ORG"'/'"$GITHUB_REPO"':environment:production",
       "audiences": ["api://AzureADTokenExchange"]
     }'
   ```

    PowerShell:
    ```powershell
    $subject = "repo:$env:GITHUB_ORG/$env:GITHUB_REPO:environment:production"
    $payload = @{
       name      = "github-env-credential"
       issuer    = "https://token.actions.githubusercontent.com"
       subject   = $subject
       audiences = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Depth 4

      az ad app federated-credential create --id $env:APP_OBJECT_ID --parameters $payload
    ```

## Step 3: Assign Azure Permissions

The service principal needs appropriate permissions to access Azure resources.

1. **Assign a role to the service principal**:
   
   First, set your subscription ID as a variable (if not already set):
   ```bash
   export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
   ```

   PowerShell:
   ```powershell
   $env:SUBSCRIPTION_ID = (az account show --query id -o tsv)
   ```
   
   For read-only access:
   
    First, capture the service principal **object id** (recommended for role assignments):
    ```bash
    export SP_OBJECT_ID=$(az ad sp show --id $APP_ID --query id -o tsv)
    ```

    PowerShell:
    ```powershell
    $env:SP_OBJECT_ID = (az ad sp show --id $env:APP_ID --query id -o tsv)
    ```

   ```bash
   az role assignment create \
       --assignee-object-id $SP_OBJECT_ID \
       --assignee-principal-type ServicePrincipal \
     --role Reader \
     --scope /subscriptions/$SUBSCRIPTION_ID
   ```

    PowerShell:
    ```powershell
    az role assignment create `
       --assignee-object-id $env:SP_OBJECT_ID `
       --assignee-principal-type ServicePrincipal `
       --role Reader `
       --scope "/subscriptions/$env:SUBSCRIPTION_ID"
    ```

   For contributor access (allows resource creation/modification):
   ```bash
   az role assignment create \
       --assignee-object-id $SP_OBJECT_ID \
       --assignee-principal-type ServicePrincipal \
     --role Contributor \
     --scope /subscriptions/$SUBSCRIPTION_ID
   ```

    PowerShell:
    ```powershell
    az role assignment create `
       --assignee-object-id $env:SP_OBJECT_ID `
       --assignee-principal-type ServicePrincipal `
       --role Contributor `
       --scope "/subscriptions/$env:SUBSCRIPTION_ID"
    ```

2. **Verify role assignment**:
   ```bash
   az role assignment list --assignee-object-id $SP_OBJECT_ID --output table
   ```

   PowerShell:
   ```powershell
   az role assignment list --assignee-object-id $env:SP_OBJECT_ID --output table
   ```

## Step 4: Configure GitHub Repository Variables and Secrets

These values are **identifiers**, not credentials:
- `AZURE_CLIENT_ID` (app/client ID), `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID` are not passwords or tokens.
- Azure OIDC security does **not** depend on keeping these values secret.
- In other words: **none of these values need to be stored as secrets** for OIDC to be secure.

That said, you may still choose to store any or all of them as GitHub **secrets** for defense-in-depth (for example, to reduce accidental exposure of environment metadata in logs or screenshots).

This repository’s workflow is set up to use:
- `AZURE_CLIENT_ID` as a GitHub Actions **repository variable** (non-secret)
- `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` as GitHub Actions **repository secrets**

1. **Navigate to GitHub Repository Settings**:
   - Go to your repository on GitHub
   - Click **Settings** → **Secrets and variables** → **Actions**

2. **Add the following repository variable / secrets**:

   | Name | Type | Description | How to Get |
   |------|------|-------------|------------|
   | `AZURE_CLIENT_ID` | Variable | Application (client) ID | From Step 1, or print `APP_ID` |
   | `AZURE_TENANT_ID` | Secret | Microsoft Entra tenant ID | From Step 1, or run `az account show --query tenantId -o tsv` |
   | `AZURE_SUBSCRIPTION_ID` | Secret | Azure Subscription ID | From Step 1, or run `az account show --query id -o tsv` |

3. **Create the variable + secrets**:
   - For `AZURE_CLIENT_ID`: click **Variables** → **New repository variable**
   - For `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`: click **Secrets** → **New repository secret**

> ⚠️ **Important**: These values are identifiers (not credentials), but you should still avoid committing environment-specific IDs to your repository. Store them in GitHub Actions variables/secrets to keep the repo reusable and to avoid leaking tenant/subscription metadata.

> Optional: If you prefer storing `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` as **variables** instead of secrets, update the workflow to use `vars.AZURE_TENANT_ID` and `vars.AZURE_SUBSCRIPTION_ID` (and update the “required repo config” checks accordingly).

## Step 5: Verify Configuration

This repository includes a workflow to validate your Azure OIDC configuration.

1. **Navigate to Actions tab** in your GitHub repository

2. **Select "Azure OIDC Connectivity Check"** from the workflows list

3. **Click "Run workflow"** → **Run workflow** (on your desired branch)

4. **Monitor the workflow run**:
   - ✅ If successful, your Azure OIDC is configured correctly
   - ❌ If it fails, check the [Troubleshooting](#troubleshooting) section below

The workflow performs the following checks:
- Verifies required GitHub Actions variables/secrets are configured
- Attempts to authenticate with Azure using OIDC
- Runs `az account show` to confirm connectivity

## Troubleshooting

### Error: "AADSTS70021: No matching federated identity record found"

**Cause**: The federated credential subject doesn't match the GitHub context.

**Solution**:
- Verify the subject in your federated credential matches your repository structure:
  ```
  repo:OWNER/REPO:ref:refs/heads/BRANCH
  ```
- Ensure you're running the workflow from the branch specified in the credential
- Check for typos in organization or repository name

### Error: "AZURE_CLIENT_ID repository variable is not configured"

**Cause**: Required GitHub Actions variable is missing.

**Solution**:
- Go to Repository Settings → Secrets and variables → Actions
- Verify the variable exists: `AZURE_CLIENT_ID`
- Verify the secrets exist: `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- Ensure names match exactly (case-sensitive)

### Error: "Authorization failed"

**Cause**: The service principal doesn't have sufficient permissions.

**Solution**:
- Verify role assignments: `az role assignment list --assignee-object-id $SP_OBJECT_ID`
- Ensure the service principal has at least Reader role on the subscription
- Wait a few minutes after creating role assignments (propagation delay)

### Error: "Subscription not found"

**Cause**: Incorrect subscription ID or service principal doesn't have access.

**Solution**:
- Verify subscription ID: `az account show --query id -o tsv`
- Check if the subscription is active: `az account list -o table`
- Ensure the service principal has been assigned a role in the subscription

### Workflow succeeds but Azure CLI commands fail

**Cause**: Service principal lacks specific permissions for resources or operations.

**Solution**:
- Review the specific permission required for the operation
- Assign appropriate role (e.g., Contributor instead of Reader)
- Consider using custom roles for least-privilege access

## Additional Resources

- **Azure Documentation**: [Configure OpenID Connect in Azure](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure)
- **GitHub Documentation**: [Security hardening with OpenID Connect](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- **azure/login Action**: [GitHub Marketplace](https://github.com/marketplace/actions/azure-login)
- **README**: See the [Post-Creation Checklist](../README.md#post-creation-checklist) for context on when to configure Azure OIDC

## Documentation Test History
### 2025-12-20
- Result: PARTIAL
- Platform/Context: GitHub Codespaces (Dev Container)
- OS: Ubuntu 24.04.3 LTS
- Shell: bash (version not captured)
- Tester: Automated Documentation Tester (with human intervention)
- Notes: `az login` blocked by org access policy/Conditional Access; requires manual sign-in (for example `az login --use-device-code`) before remaining steps can be executed.

### 2025-12-20
- Result: PASS with fixes
- Platform/Context: Local machine
- OS: Microsoft Windows (Version 10.0.26200.7392)
- Shell: PowerShell 7.5.4 (Core)
- Tester: Automated Documentation Tester (with human intervention)
- Notes: Completed Entra app + service principal creation, federated credential creation (required using application object id in `az ad app federated-credential`), Reader RBAC assignment, and successfully ran the "Azure OIDC Connectivity Check" workflow. Human steps: authenticated `az login`, configured GitHub Actions variable/secret values in the repo settings UI, and clicked "Run workflow".

