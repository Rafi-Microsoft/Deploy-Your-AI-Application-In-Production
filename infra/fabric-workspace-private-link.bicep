// ================================================================
// Fabric Workspace Private Link & Private Endpoint (Post-provision)
// ================================================================
// Deploys:
//   1. Microsoft.Fabric/privateLinkServicesForFabric@2024-06-01
//      (workspace-level Fabric private link service - new in 2024-06)
//   2. Microsoft.Network/privateEndpoints@2025-07-01 targeting
//      groupId='workspace' on the VNet's PE subnet
//   3. (Optional) Private DNS zone group binding for resolution
//
// Why it lives outside main.bicep:
//   The Fabric workspace GUID is only known AFTER the post-provision
//   PowerShell script `create_fabric_workspace.ps1` creates it.
//   This template is therefore deployed by a postprovision hook,
//   not by `azd up`'s main bicep run.
//
// References:
//   - https://learn.microsoft.com/fabric/security/security-workspace-level-private-links-set-up
//   - https://learn.microsoft.com/azure/templates/microsoft.fabric/privatelinkservicesforfabric
// ================================================================

targetScope = 'resourceGroup'

metadata name = 'Fabric Workspace Private Link (post-provision)'
metadata description = 'Creates the Microsoft.Fabric private link service and the corresponding VNet private endpoint for a Fabric workspace.'

// ========================================
// PARAMETERS
// ========================================

@description('Fabric workspace GUID (from create_fabric_workspace.ps1 → FABRIC_WORKSPACE_ID).')
param fabricWorkspaceId string

@description('Azure AD tenant ID hosting the Fabric workspace.')
param tenantId string = subscription().tenantId

@description('Azure region for the private endpoint NIC. Must match the VNet region.')
param location string = resourceGroup().location

@description('Resource ID of the subnet where the private endpoint NIC will live (typically the PE subnet).')
param privateEndpointSubnetId string

@description('Optional name for the private link service resource. Defaults to the workspace GUID.')
param privateLinkServiceName string = fabricWorkspaceId

@description('Name for the private endpoint resource.')
param privateEndpointName string = 'pe-fabric-workspace-${take(replace(fabricWorkspaceId, '-', ''), 10)}'

@description('Tags applied to created resources.')
param tags object = {}

@description('Resource IDs of pre-existing private DNS zones to bind to the PE (privatelink.analysis.windows.net, privatelink.pbidedicated.windows.net, privatelink.prod.powerquery.microsoft.com).')
param privateDnsZoneIds array = []

@description('Bind the private DNS zone group on the PE.')
param enablePrivateDnsIntegration bool = true

// ========================================
// MODULE: Fabric Private Link Service
// ========================================

module fabricPrivateLinkService 'modules/fabricPrivateLinkService.bicep' = {
  name: 'fabric-pls-deploy'
  params: {
    privateLinkServiceName: privateLinkServiceName
    workspaceId: fabricWorkspaceId
    tenantId: tenantId
    tags: tags
  }
}

// ========================================
// MODULE: VNet Private Endpoint → workspace
// ========================================

module fabricPrivateEndpoint 'modules/fabricPrivateEndpoint.bicep' = {
  name: 'fabric-pe-deploy'
  params: {
    privateEndpointName: privateEndpointName
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    fabricWorkspaceResourceId: fabricPrivateLinkService.outputs.resourceId
    enablePrivateDnsIntegration: enablePrivateDnsIntegration
    privateDnsZoneIds: privateDnsZoneIds
  }
}

// ========================================
// OUTPUTS
// ========================================

output privateLinkServiceResourceId string = fabricPrivateLinkService.outputs.resourceId
output privateEndpointResourceId string = fabricPrivateEndpoint.outputs.privateEndpointId
output privateEndpointName string = fabricPrivateEndpoint.outputs.privateEndpointName
output privateEndpointIpAddress string = fabricPrivateEndpoint.outputs.privateEndpointIpAddress
output networkInterfaceId string = fabricPrivateEndpoint.outputs.networkInterfaceId
