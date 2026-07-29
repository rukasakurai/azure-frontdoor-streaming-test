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
    // This harness currently uses local auth so ephemeral E2E deployments can
    // exercise Foundry streaming without extra pre-provisioned identity setup.
    // If changing this to managed identity or another auth model, account for the
    // resulting E2E setup, permissions, cleanup, and secret-handling tradeoffs.
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
