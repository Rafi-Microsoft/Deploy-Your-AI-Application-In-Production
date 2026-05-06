<#
.SYNOPSIS
  Deploys the Microsoft.Fabric/privateLinkServicesForFabric resource
  and a VNet-side private endpoint for the Fabric workspace.

.DESCRIPTION
  Wraps `infra/fabric-workspace-private-link.bicep` and runs it via
  `az deployment group create` AFTER the Fabric workspace GUID is known
  (i.e., after `create_fabric_workspace.ps1`).

  This unblocks Phase-2 of the DYAIAPP private networking story:
    - Workspace-level Fabric private link service (new ARM RP, apiVersion 2024-06-01)
    - VNet private endpoint with groupId='workspace'
    - DNS zone group binding (when zones exist)

  Gated by env var FABRIC_ENABLE_WORKSPACE_PRIVATE_ENDPOINT=true
  (matches the existing toggle used by setup_fabric_private_link.ps1).

  References:
    - https://learn.microsoft.com/fabric/security/security-workspace-level-private-links-set-up
    - https://learn.microsoft.com/azure/templates/microsoft.fabric/privatelinkservicesforfabric

.NOTES
  Idempotent. Re-running with the same workspace GUID is a no-op.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Log([string]$m){ Write-Host "[fabric-workspace-pe] $m" -ForegroundColor Cyan }
function Warn([string]$m){ Write-Warning "[fabric-workspace-pe] $m" }
function Fail([string]$m){ Write-Error "[fabric-workspace-pe] $m"; exit 1 }

function ConvertTo-Bool {
  param([object]$Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [bool]) { return $Value }
  $text = $Value.ToString().Trim().ToLowerInvariant()
  return $text -in @('1','true','yes','y','on','enable','enabled')
}

# ----------------------------------------------------------------
# 1. Toggle gate
# ----------------------------------------------------------------
$toggle = [System.Environment]::GetEnvironmentVariable('FABRIC_ENABLE_WORKSPACE_PRIVATE_ENDPOINT')
if (-not $toggle) {
  try { $toggle = (& azd env get-value FABRIC_ENABLE_WORKSPACE_PRIVATE_ENDPOINT 2>$null) } catch {}
}
if (-not (ConvertTo-Bool $toggle)) {
  Log "Toggle FABRIC_ENABLE_WORKSPACE_PRIVATE_ENDPOINT not set; skipping."
  exit 0
}

Log "=================================================================="
Log "Deploying Fabric workspace private link + VNet private endpoint"
Log "=================================================================="

# ----------------------------------------------------------------
# 2. Resolve required azd env values
# ----------------------------------------------------------------
$envValues = @{}
try {
  $raw = azd env get-values 2>$null
  foreach ($line in $raw) {
    if ($line -match '^(.+?)=(.*)$') { $envValues[$matches[1]] = $matches[2].Trim('"') }
  }
} catch {
  Warn "Failed to read azd env values: $($_.Exception.Message)"
  exit 0
}

function Pick([string[]]$keys) {
  foreach ($k in $keys) { if ($envValues.ContainsKey($k) -and $envValues[$k]) { return $envValues[$k] } }
  return $null
}

$subscriptionId = Pick @('AZURE_SUBSCRIPTION_ID', 'subscriptionId')
$resourceGroup  = Pick @('AZURE_RESOURCE_GROUP', 'resourceGroupName')
$location       = Pick @('AZURE_LOCATION', 'location')
$peSubnetId     = Pick @('peSubnetResourceId', 'PE_SUBNET_RESOURCE_ID')
$tenantId       = Pick @('AZURE_TENANT_ID', 'tenantId')
$workspaceId    = Pick @('FABRIC_WORKSPACE_ID')
if (-not $workspaceId) { $workspaceId = $env:FABRIC_WORKSPACE_ID }

if (-not $tenantId) { try { $tenantId = (az account show --query tenantId -o tsv 2>$null) } catch {} }

if (-not $subscriptionId -or -not $resourceGroup -or -not $peSubnetId -or -not $workspaceId) {
  Warn "Missing required values:"
  Warn "  subscriptionId=$subscriptionId"
  Warn "  resourceGroup=$resourceGroup"
  Warn "  peSubnetResourceId=$peSubnetId"
  Warn "  FABRIC_WORKSPACE_ID=$workspaceId"
  Warn "Run 'azd up' to deploy infra and 'create_fabric_workspace.ps1' to create the workspace first."
  exit 0
}

Log "Subscription : $subscriptionId"
Log "ResourceGroup: $resourceGroup"
Log "PE subnet    : $peSubnetId"
Log "Workspace ID : $workspaceId"

# ----------------------------------------------------------------
# 3. One-time prerequisite: register Microsoft.Fabric provider
# ----------------------------------------------------------------
try {
  $state = az provider show --namespace Microsoft.Fabric --query registrationState -o tsv 2>$null
  if ($state -ne 'Registered') {
    Log "Registering Microsoft.Fabric resource provider (one-time)..."
    az provider register --namespace Microsoft.Fabric --wait | Out-Null
    Log "Provider registered."
  } else {
    Log "Microsoft.Fabric provider already registered."
  }
} catch {
  Fail "Failed to register Microsoft.Fabric provider: $($_.Exception.Message)"
}

# ----------------------------------------------------------------
# 4. Resolve existing private DNS zone IDs (created by
#    create_fabric_private_dns_zones.ps1 - optional)
# ----------------------------------------------------------------
$dnsZoneNames = @(
  'privatelink.analysis.windows.net',
  'privatelink.pbidedicated.windows.net',
  'privatelink.prod.powerquery.microsoft.com'
)
$dnsZoneIds = @()
foreach ($zoneName in $dnsZoneNames) {
  $zoneId = az network private-dns zone show --name $zoneName --resource-group $resourceGroup --query id -o tsv 2>$null
  if ($LASTEXITCODE -eq 0 -and $zoneId) {
    Log "  Found DNS zone: $zoneName"
    $dnsZoneIds += $zoneId
  } else {
    Warn "  DNS zone $zoneName not found; PE will be deployed without DNS zone group binding for this zone."
  }
}
$enableDnsIntegration = ($dnsZoneIds.Count -gt 0)

# ----------------------------------------------------------------
# 5. Deploy the wrapper bicep
# ----------------------------------------------------------------
$repoRoot     = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')
$bicepPath    = Join-Path $repoRoot 'infra\fabric-workspace-private-link.bicep'
$deployment   = "fabric-workspace-pe-$(Get-Date -Format 'yyyyMMddHHmmss')"

if (-not (Test-Path $bicepPath)) { Fail "Bicep template not found: $bicepPath" }

Log "Submitting deployment '$deployment'..."

$dnsZoneIdsJson = ($dnsZoneIds | ConvertTo-Json -Compress -AsArray)
if (-not $dnsZoneIdsJson) { $dnsZoneIdsJson = '[]' }

$result = az deployment group create `
  --name $deployment `
  --resource-group $resourceGroup `
  --subscription $subscriptionId `
  --template-file $bicepPath `
  --parameters `
    fabricWorkspaceId=$workspaceId `
    tenantId=$tenantId `
    location=$location `
    privateEndpointSubnetId=$peSubnetId `
    enablePrivateDnsIntegration=$enableDnsIntegration `
    privateDnsZoneIds=$dnsZoneIdsJson `
  --only-show-errors `
  --output json 2>&1

if ($LASTEXITCODE -ne 0) {
  Fail "Deployment failed: $result"
}

$parsed = $result | ConvertFrom-Json
Log ""
Log "=== Deployment succeeded ==="
Log "Private link service : $($parsed.properties.outputs.privateLinkServiceResourceId.value)"
Log "Private endpoint     : $($parsed.properties.outputs.privateEndpointName.value)"
Log "Private endpoint IP  : $($parsed.properties.outputs.privateEndpointIpAddress.value)"

# Persist PE IP for downstream verification scripts
try {
  azd env set FABRIC_WORKSPACE_PE_IP $parsed.properties.outputs.privateEndpointIpAddress.value | Out-Null
} catch {}

exit 0
