#Requires -Version 7.0

# CSToolkit - multi-tenant Microsoft 365 management toolkit.
# Private/ holds internal helpers, Public/ holds the exported commands (one function per file).

$script:ToolkitRoot = Split-Path -Parent $PSScriptRoot      # .../M365
$script:ConfigPath  = Join-Path $script:ToolkitRoot 'Config'
$script:DataPath    = Join-Path $script:ToolkitRoot 'Data'

# Session state. Lives in memory only - tokens are never written to disk.
$script:CSSession = $null       # partner sign-in: ClientId, PartnerTenantId, Account, RefreshToken, TokenCache
$script:CSContext = $null       # current tenant: Tenant (registry row), AccessToken, ExpiresOn (set by the runner / Set-CSContext)

foreach ($folder in 'Private', 'Public') {
    foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' -File) {
        . $file.FullName
    }
}

Export-ModuleMember -Function (Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File).BaseName
