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

#disable-next-line outputs-should-not-contain-secrets
output apiKey string = account.listKeys().key1
