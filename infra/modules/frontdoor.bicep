@description('Name of the Azure Front Door profile.')
param name string

@description('Resource tags.')
param tags object = {}

@description('Hostname of the origin App Service (without https://).')
param originHostName string

@description('Unique token used to avoid resource-name collisions (e.g. uniqueString output).')
param resourceToken string

@description('Resource ID of the Log Analytics workspace that receives Front Door access logs.')
param logAnalyticsWorkspaceId string

var originGroupName = 'app-origin-group'
var originName = 'app-origin'
var endpointName = 'ep-${resourceToken}'
var routeName = 'default-route'
var ruleSetName = 'cacheRules'

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
  dependsOn: [
    origin
    baselineCacheRule
    optimizedCacheRule
  ]
  properties: {
    enabledState: 'Enabled'
    originGroup: {
      id: originGroup.id
    }
    supportedProtocols: ['Https']
    patternsToMatch: ['/*']
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    ruleSets: [
      {
        id: ruleSet.id
      }
    ]
  }
}

resource ruleSet 'Microsoft.Cdn/profiles/ruleSets@2024-09-01' = {
  parent: afdProfile
  name: ruleSetName
}

resource baselineCacheRule 'Microsoft.Cdn/profiles/ruleSets/rules@2024-09-01' = {
  parent: ruleSet
  name: 'baselineUseQueryString'
  properties: {
    order: 1
    matchProcessingBehavior: 'Stop'
    conditions: [
      {
        name: 'UrlPath'
        parameters: {
          operator: 'BeginsWith'
          negateCondition: false
          matchValues: [
            'cache-baseline/static-test/query/'
          ]
          transforms: []
          typeName: 'DeliveryRuleUrlPathMatchConditionParameters'
        }
      }
    ]
    actions: [
      {
        name: 'RouteConfigurationOverride'
        parameters: {
          cacheConfiguration: {
            queryStringCachingBehavior: 'UseQueryString'
            isCompressionEnabled: 'Enabled'
            cacheBehavior: 'HonorOrigin'
            cacheDuration: null
          }
          originGroupOverride: null
          typeName: 'DeliveryRuleRouteConfigurationOverrideActionParameters'
        }
      }
    ]
  }
}

resource optimizedCacheRule 'Microsoft.Cdn/profiles/ruleSets/rules@2024-09-01' = {
  parent: ruleSet
  name: 'optimizedIgnoreQueryString'
  properties: {
    order: 2
    matchProcessingBehavior: 'Stop'
    conditions: [
      {
        name: 'UrlPath'
        parameters: {
          operator: 'BeginsWith'
          negateCondition: false
          matchValues: [
            'static-test/'
          ]
          transforms: []
          typeName: 'DeliveryRuleUrlPathMatchConditionParameters'
        }
      }
    ]
    actions: [
      {
        name: 'RouteConfigurationOverride'
        parameters: {
          cacheConfiguration: {
            queryStringCachingBehavior: 'IgnoreQueryString'
            isCompressionEnabled: 'Enabled'
            cacheBehavior: 'HonorOrigin'
            cacheDuration: null
          }
          originGroupOverride: null
          typeName: 'DeliveryRuleRouteConfigurationOverrideActionParameters'
        }
      }
    ]
  }
}

// Latest stable diagnosticSettings API does not support scoped extension resources for this target.
resource accessLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'frontdoor-access-logs'
  scope: afdProfile
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: false
        retentionPolicy: {
          days: 0
          enabled: false
        }
      }
    ]
  }
}

output profileId string = afdProfile.id
output endpointHostName string = endpoint.properties.hostName
