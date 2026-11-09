function Sync-CSTenantRegistry {
    <#
    .SYNOPSIS
        Builds / refreshes Config/tenants.csv from your GDAP relationships.

    .DESCRIPTION
        Lists delegatedAdminRelationships from the partner tenant and merges them into the CSV:
          - new tenants are appended (Customer defaults to the tenant name)
          - DisplayName, DefaultDomain and GdapStatus are refreshed
          - Customer, Group, Profile, Features, Enabled and Notes are yours and are never overwritten
          - tenants whose relationship is gone are kept and marked GdapStatus = Missing
        The previous file is copied to tenants.csv.bak before it is replaced. Supports -WhatIf.

        Needs Connect-CSPartner first. DefaultDomain needs the CrossTenantInformation.ReadBasic.All scope; if that lookup is denied,
        the column is left blank with a warning.

    .PARAMETER IncludeInactive
        Also add tenants whose only relationships are expired or terminated.

    .EXAMPLE
        Sync-CSTenantRegistry -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [string]$Path = (Join-Path $script:ConfigPath 'tenants.csv'),

        [switch]$IncludeInactive
    )

    Assert-CSSession

    $partner = Get-CSTenantToken -TenantId $script:CSSession.PartnerTenantId -Scope 'https://graph.microsoft.com/DelegatedAdminRelationship.Read.All https://graph.microsoft.com/CrossTenantInformation.ReadBasic.All'
    $ctx     = [pscustomobject]@{ AccessToken = $partner.AccessToken }

    Write-Host 'Reading GDAP relationships...' -ForegroundColor Cyan
    $relationships = @(Invoke-CSGraph '/tenantRelationships/delegatedAdminRelationships?$select=id,status,customer' -Context $ctx)

    $activeStates = 'active', 'expiring'
    $source = foreach ($group in ($relationships | Where-Object { $_.customer.tenantId } | Group-Object { $_.customer.tenantId })) {
        [pscustomobject]@{
            TenantId      = $group.Name
            DisplayName   = ($group.Group | Where-Object { $_.customer.displayName } | Select-Object -First 1).customer.displayName
            DefaultDomain = ''
            GdapActive    = [bool]($group.Group | Where-Object { $_.status -in $activeStates })
        }
    }

    $existing = if (Test-Path -LiteralPath $Path) { @(Import-Csv -LiteralPath $Path) } else { @() }
    $known    = @{}
    foreach ($row in $existing) { $known[$row.TenantId.ToLowerInvariant()] = $row }

    if (-not $IncludeInactive) {
        $source = @($source | Where-Object { $_.GdapActive -or $known.ContainsKey($_.TenantId.ToLowerInvariant()) })
    }

    # Resolve the default (onmicrosoft.com) domain for tenants that don't have one yet.
    $needDomain = @($source | Where-Object { -not ($known[$_.TenantId.ToLowerInvariant()].DefaultDomain) })
    $lookupDenied = $false
    for ($i = 0; $i -lt $needDomain.Count -and -not $lookupDenied; $i++) {
        $tenant = $needDomain[$i]
        Write-Progress -Activity 'Resolving tenant domains' -Status $tenant.DisplayName -PercentComplete (($i / $needDomain.Count) * 100)
        try {
            $info = Invoke-CSGraph "/tenantRelationships/findTenantInformationByTenantId(tenantId='$($tenant.TenantId)')" -Context $ctx
            $tenant.DefaultDomain = $info.defaultDomainName
        }
        catch {
            if ($_.FullyQualifiedErrorId -eq 'CSGraph.Forbidden') {
                $lookupDenied = $true
                Write-Warning 'Cannot resolve default domains (CrossTenantInformation.ReadBasic.All not consented). DefaultDomain left blank.'
            }
            else { Write-Warning "Domain lookup failed for $($tenant.DisplayName): $($_.Exception.Message)" }
        }
    }
    Write-Progress -Activity 'Resolving tenant domains' -Completed

    $merge = Merge-CSTenantRegistry -Existing $existing -Source $source

    Write-Host ("Registry: {0} added, {1} updated, {2} missing from GDAP, {3} total" -f $merge.Added.Count, $merge.Updated.Count, $merge.Missing.Count, $merge.Rows.Count) -ForegroundColor Green
    foreach ($id in $merge.Added)   { Write-Host "  + $id" -ForegroundColor Green }
    foreach ($id in $merge.Missing) { Write-Host "  ! $id no longer has a GDAP relationship" -ForegroundColor Yellow }

    if ($PSCmdlet.ShouldProcess($Path, 'Write tenant registry')) {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (Test-Path -LiteralPath $Path) { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force }
        $merge.Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
        Write-Host "Wrote $Path" -ForegroundColor Green
    }

    [pscustomobject]@{ Path = $Path; Added = $merge.Added; Updated = $merge.Updated; Missing = $merge.Missing; Total = $merge.Rows.Count }
}
