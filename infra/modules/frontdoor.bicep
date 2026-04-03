@description('Name of the Azure Front Door profile.')
param name string

@description('Resource tags.')
param tags object = {}

@description('Hostname of the origin App Service (without https://).')
param originHostName string

@description('Unique token used to avoid resource-name collisions (e.g. uniqueString output).')
param resourceToken string

var originGroupName = 'app-origin-group'
var originName = 'app-origin'
var endpointName = 'ep-${resourceToken}'
var routeName = 'default-route'

resource afdProfile 'Microsoft.Cdn/profiles@2024-09-01' = {
  name: name
  location: 'global'
  tags: tags
  sku: {
    name: 'Premium_AzureFrontDoor'
  }
  properties: {
    originResponseTimeoutSeconds: 240
  }
}

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2024-09-01' = {
  parent: afdProfile
  name: originGroupName
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/health'
      probeRequestType: 'GET'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 30
    }
    sessionAffinityState: 'Disabled'
  }
}

resource origin 'Microsoft.Cdn/profiles/originGroups/origins@2024-09-01' = {
  parent: originGroup
  name: originName
  properties: {
    hostName: originHostName
    httpPort: 80
    httpsPort: 443
    originHostHeader: originHostName
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-09-01' = {
  parent: afdProfile
  name: endpointName
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
}

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-09-01' = {
  parent: endpoint
  name: routeName
  dependsOn: [origin]
  properties: {
    originGroup: {
      id: originGroup.id
    }
    supportedProtocols: ['Https']
    patternsToMatch: ['/*']
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    originPath: '/'
    ruleSets: [
      {
        id: ruleSet.id
      }
    ]
  }
}

// Rule set: disable caching and set origin response timeout to 240 s (maximum)
resource ruleSet 'Microsoft.Cdn/profiles/ruleSets@2024-09-01' = {
  parent: afdProfile
  name: 'streamingRules'
}

resource originTimeoutRule 'Microsoft.Cdn/profiles/ruleSets/rules@2024-09-01' = {
  parent: ruleSet
  name: 'setOriginTimeout'
  properties: {
    order: 1
    conditions: []
    actions: [
      {
        name: 'RouteConfigurationOverride'
        parameters: {
          typeName: 'DeliveryRuleRouteConfigurationOverrideActionParameters'
          originGroupOverride: {
            originGroup: {
              id: originGroup.id
            }
            forwardingProtocol: 'HttpsOnly'
          }
        }
      }
    ]
  }
}

output profileId string = afdProfile.id
output endpointHostName string = endpoint.properties.hostName
