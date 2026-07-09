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
var appServiceName = '${abbrs.webSitesAppService}${resourceToken}'
var foundryName = '${abbrs.cognitiveServicesAccounts}${resourceToken}'
var cognitiveServicesOpenAIUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')

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
    name: appServiceName
    location: location
    tags: tags
    appServicePlanId: appServicePlan.outputs.id
    foundryEndpoint: foundry.outputs.endpoint
    foundryDeploymentName: foundry.outputs.deploymentName
  }
}

module foundry './modules/foundry.bicep' = {
  name: 'foundry'
  params: {
    name: foundryName
    location: location
    tags: tags
  }
}

module logAnalytics './modules/loganalytics.bicep' = {
  name: 'loganalytics'
  params: {
    name: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    location: location
    tags: tags
  }
}

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
}

resource foundryOpenAIUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryAccount.id, appServiceName, cognitiveServicesOpenAIUserRoleId)
  scope: foundryAccount
  properties: {
    roleDefinitionId: cognitiveServicesOpenAIUserRoleId
    principalId: appService.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

module frontDoor './modules/frontdoor.bicep' = {
  name: 'frontdoor'
  params: {
    name: '${abbrs.networkFrontDoors}${resourceToken}'
    tags: tags
    originHostName: appService.outputs.defaultHostName
    resourceToken: resourceToken
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
  }
}

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output SERVICE_APP_NAME string = appService.outputs.name
output SERVICE_APP_URI string = 'https://${appService.outputs.defaultHostName}'
output AFD_URI string = 'https://${frontDoor.outputs.endpointHostName}'
output AFD_BASELINE_URI string = 'https://${frontDoor.outputs.endpointHostName}/cache-baseline'
output LOG_ANALYTICS_WORKSPACE_NAME string = logAnalytics.outputs.name
output LOG_ANALYTICS_WORKSPACE_ID string = logAnalytics.outputs.id
output LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID string = logAnalytics.outputs.customerId
