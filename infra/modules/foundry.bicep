@description('Name of the Cognitive Services account.')
param name string

@description('Azure region for the resource.')
param location string

@description('Resource tags.')
param tags object = {}

@description('Name of the model deployment.')
param deploymentName string = 'gpt-4o-mini'

@description('Model name to deploy.')
param modelName string = 'gpt-4o-mini'

@description('Model version to deploy.')
param modelVersion string = '2024-07-18'

@description('Deployment capacity (tokens per minute in thousands).')
param deploymentCapacity int = 1

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    // Keep local auth enabled so this self-contained E2E harness can create a new
    // resource group and immediately test Foundry streaming without requiring the
    // GitHub Actions principal to create RBAC assignments. Managed identity auth is
    // a valid target architecture, but it requires either role-assignment privileges
    // during E2E or pre-managed identity infrastructure outside this template.
    disableLocalAuth: false
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: deploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: deploymentCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

output endpoint string = account.properties.endpoint
output accountName string = account.name
output deploymentName string = deployment.name

@secure()
output apiKey string = account.listKeys().key1
