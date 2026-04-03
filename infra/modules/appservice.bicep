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

@secure()
@description('Microsoft Foundry API key.')
param foundryApiKey string = ''

@description('Microsoft Foundry model deployment name.')
param foundryDeploymentName string = ''

resource appService 'Microsoft.Web/sites@2024-04-01' = {
  name: name
  location: location
  tags: union(tags, { 'azd-service-name': 'app' })
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
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
          name: 'FOUNDRY_API_KEY'
          value: foundryApiKey
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
