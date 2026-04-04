targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment (used to name resources).')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string

@description('Custom tag name to apply to all resources (leave empty to skip).')
param customTagName string = ''

@description('Custom tag value (used when customTagName is set).')
param customTagValue string = ''

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var baseTags = { 'azd-env-name': environmentName }
var tags = customTagName != '' ? union(baseTags, { '${customTagName}': customTagValue }) : baseTags

resource rg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

module appServicePlan './modules/appserviceplan.bicep' = {
  name: 'appserviceplan'
  scope: rg
  params: {
    name: '${abbrs.webServerFarms}${resourceToken}'
    location: location
    tags: tags
  }
}

module appService './modules/appservice.bicep' = {
  name: 'appservice'
  scope: rg
  params: {
    name: '${abbrs.webSitesAppService}${resourceToken}'
    location: location
    tags: tags
    appServicePlanId: appServicePlan.outputs.id
    foundryEndpoint: foundry.outputs.endpoint
    foundryApiKey: foundry.outputs.apiKey
    foundryDeploymentName: foundry.outputs.deploymentName
  }
}

module foundry './modules/foundry.bicep' = {
  name: 'foundry'
  scope: rg
  params: {
    name: '${abbrs.cognitiveServicesAccounts}${resourceToken}'
    location: location
    tags: tags
  }
}

module frontDoor './modules/frontdoor.bicep' = {
  name: 'frontdoor'
  scope: rg
  params: {
    name: '${abbrs.networkFrontDoors}${resourceToken}'
    tags: tags
    originHostName: appService.outputs.defaultHostName
    resourceToken: resourceToken
  }
}

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output SERVICE_APP_NAME string = appService.outputs.name
output SERVICE_APP_URI string = 'https://${appService.outputs.defaultHostName}'
output AFD_URI string = 'https://${frontDoor.outputs.endpointHostName}'
