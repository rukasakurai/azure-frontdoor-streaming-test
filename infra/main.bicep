@minLength(1)
@maxLength(64)
@description('Name of the environment (used to name resources).')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

module appServicePlan './modules/appserviceplan.bicep' = {
  name: 'appserviceplan'
  params: {
    name: '${abbrs.webServerFarms}${resourceToken}'
    location: location
    tags: tags
  }
}

module appService './modules/appservice.bicep' = {
  name: 'appservice'
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
  params: {
    name: '${abbrs.cognitiveServicesAccounts}${resourceToken}'
    location: location
    tags: tags
  }
}

module frontDoor './modules/frontdoor.bicep' = {
  name: 'frontdoor'
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
