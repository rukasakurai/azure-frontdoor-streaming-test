@description('Name of the App Service.')
param name string

@description('Azure region for the resource.')
param location string

@description('Resource tags.')
param tags object = {}

@description('Resource ID of the App Service Plan.')
param appServicePlanId string

@description('Microsoft Foundry endpoint URL.')
param foundryEndpoint string = ''

@description('Microsoft Foundry model deployment name.')
param foundryDeploymentName string = ''

resource appService 'Microsoft.Web/sites@2024-04-01' = {
  name: name
  location: location
  tags: union(tags, { 'azd-service-name': 'app' })
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      linuxFxVersion: 'NODE|20-lts'
      appCommandLine: 'npm start'
      alwaysOn: true
      appSettings: [
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~20'
        }
        {
          name: 'FOUNDRY_ENDPOINT'
          value: foundryEndpoint
        }
        {
          name: 'FOUNDRY_AUTH_MODE'
          value: 'managed-identity'
        }
        {
          name: 'FOUNDRY_DEPLOYMENT_NAME'
          value: foundryDeploymentName
        }
      ]
    }
  }
}

output id string = appService.id
output name string = appService.name
output defaultHostName string = appService.properties.defaultHostName
output principalId string = appService.identity.principalId
