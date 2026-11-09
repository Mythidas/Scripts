@{
    RootModule            = 'CSToolkit.psm1'
    ModuleVersion         = '0.1.0'
    GUID                  = '6f0c1d6e-4c1a-4a53-9a57-2d5f0b8c7a31'
    Author                = 'Mythidas'
    Description           = 'Multi-tenant Microsoft 365 management and tenant health toolkit (GDAP).'
    PowerShellVersion     = '7.0'
    CompatiblePSEditions  = @('Core')
    FunctionsToExport     = @(
        'Connect-CSPartner',
        'Disconnect-CSPartner',
        'Expand-CSTenantRun',
        'Export-CSResult',
        'Get-CSContext',
        'Get-CSResultSummary',
        'Get-CSSession',
        'Get-CSTenant',
        'Get-CSTenantToken',
        'Invoke-CSForEachTenant',
        'Invoke-CSGraph',
        'New-CSResult',
        'Set-CSContext',
        'Sync-CSTenantRegistry'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
}
