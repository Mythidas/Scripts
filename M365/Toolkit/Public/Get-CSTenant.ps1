function Get-CSTenant {
    <#
    .SYNOPSIS
        Reads the tenant registry and returns tenant objects, optionally filtered. Pipe them into Invoke-CSForEachTenant.

    .DESCRIPTION
        Filters combine with AND; multiple values within one filter are OR. Text filters accept wildcards.
        By default disabled tenants and tenants without an active GDAP relationship are skipped (use -All).

    .PARAMETER Name
        Matches DisplayName or DefaultDomain.

    .PARAMETER Group
        Matches any one tag in the semicolon-separated Group column.

    .PARAMETER Feature
        Tenant must have every listed tag in the Features column (e.g. Intune, EntraP2).

    .EXAMPLE
        Get-CSTenant -Customer 'Acme*'

    .EXAMPLE
        Get-CSTenant -Group Dental -Profile Standard -Feature Intune
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'Parameter named Profile to match the registry column.')]
    [CmdletBinding()]
    param (
        [string[]]$Name,
        [string[]]$TenantId,
        [string[]]$Customer,
        [string[]]$Group,
        [string[]]$Profile,
        [string[]]$Feature,
        [switch]$All,
        [string]$Path = (Join-Path $script:ConfigPath 'tenants.csv')
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Tenant registry not found at $Path. Run Connect-CSPartner, then Sync-CSTenantRegistry (see Config/tenants.example.csv for the format)."
    }

    $split = { param($text) @("$text" -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $any   = { param($value, $patterns) [bool]($patterns | Where-Object { $value -like $_ }) }

    foreach ($row in Import-Csv -LiteralPath $Path) {
        $enabled = "$($row.Enabled)" -notin 'false', 'no', '0', 'n'
        $tenant  = [pscustomobject]@{
            PSTypeName    = 'CS.Tenant'
            TenantId      = $row.TenantId
            DefaultDomain = $row.DefaultDomain
            DisplayName   = $row.DisplayName
            Customer      = $row.Customer
            Group         = [string[]](& $split $row.Group)
            Profile       = $row.Profile
            Features      = [string[]](& $split $row.Features)
            Enabled       = $enabled
            GdapStatus    = $row.GdapStatus
            Notes         = $row.Notes
        }

        if (-not $All -and (-not $enabled -or $row.GdapStatus -in 'Missing', 'Inactive')) { continue }
        if ($Name     -and -not ((& $any $tenant.DisplayName $Name) -or (& $any $tenant.DefaultDomain $Name))) { continue }
        if ($TenantId -and $tenant.TenantId -notin $TenantId) { continue }
        if ($Customer -and -not (& $any $tenant.Customer $Customer)) { continue }
        if ($Profile  -and -not (& $any $tenant.Profile $Profile)) { continue }
        if ($Group    -and -not ($tenant.Group | Where-Object { & $any $_ $Group })) { continue }
        if ($Feature  -and ($Feature | Where-Object { $_ -notin $tenant.Features })) { continue }

        $tenant
    }
}
