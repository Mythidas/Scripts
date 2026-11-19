#Requires -Version 7.0

# CSToolkit - multi-tenant Microsoft 365 management toolkit.
# Private/ holds internal helpers, Public/ holds the exported commands (one function per file).

$script:ToolkitRoot = Split-Path -Parent $PSScriptRoot      # .../M365
$script:ConfigPath  = Join-Path $script:ToolkitRoot 'Config'
$script:DataPath    = Join-Path $script:ToolkitRoot 'Data'

# Session state. Lives in memory only - tokens are never written to disk.
$script:CSSession = $null       # partner sign-in: ClientId, PartnerTenantId, Account, RefreshToken, TokenCache
$script:CSContext = $null       # current tenant: Tenant (registry row), AccessToken, ExpiresOn (set by the runner / Set-CSContext)

# App registration. Register-CSPartnerApp writes Config/settings.json; until then the public Graph CLI client is used.
$script:SettingsPath      = Join-Path $script:ConfigPath 'settings.json'
$script:BootstrapClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'   # Microsoft Graph Command Line Tools
$script:GraphAppId        = '00000003-0000-0000-c000-000000000000'
$script:PartnerCenterAppId = 'fa3d9a0c-3fb0-42cc-9193-47c7ecd2edbd'  # Microsoft Partner Center API

# Delegated Graph permissions consented in every customer tenant (read-only health checks).
# Add to this list, re-run Register-CSPartnerApp, then Grant-CSTenantConsent -Force to roll new permissions out.
$script:CustomerGraphScopes = @(
    'User.Read.All'
    'Directory.Read.All'
    'Organization.Read.All'
    'Domain.Read.All'
    'Policy.Read.All'
    'RoleManagement.Read.Directory'
    'AuditLog.Read.All'
    'Reports.Read.All'
    'UserAuthenticationMethod.Read.All'
    'DeviceManagementManagedDevices.Read.All'
    'SecurityEvents.Read.All'
)
# Extra delegated Graph permissions only needed in the partner tenant (registry sync).
$script:PartnerGraphScopes = @('DelegatedAdminRelationship.Read.All', 'CrossTenantInformation.ReadBasic.All')

foreach ($folder in 'Private', 'Public') {
    foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' -File) {
        . $file.FullName
    }
}

Export-ModuleMember -Function (Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File).BaseName
