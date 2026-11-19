#Requires -Version 7.0

<#
.SYNOPSIS
    Tenant health check: verifies each GDAP tenant meets our baseline. Currently checks that the standard CS accounts exist.

.DESCRIPTION
    Read-only. For every selected tenant it looks for a user whose UPN starts with each standard account name
    (cstech@, csadmin@, csbreakglass@ by default) on any of the tenant's domains.

    Per account, per tenant:
      Pass   exactly one matching account, enabled
      Warn   account exists but is disabled, or more than one match (e.g. on two domains) - see Detail
      Fail   no matching account
      Error  could not read users in that tenant (GDAP role / consent) - not a Fail

    Output: a Tenant x Account grid on screen, plus Data/Reports/TenantHealth-<timestamp>.csv and .json

.PARAMETER Name
    Tenant display name or domain (wildcards).

.PARAMETER Customer
    Customer name (wildcards).

.PARAMETER Group
    Group tag from the registry.

.PARAMETER TenantId
    One or more tenant IDs.

.PARAMETER ThrottleLimit
    Tenants processed at once. Default 5.

.PARAMETER AccountName
    UPN prefixes (the part before @) that every tenant must have.

.PARAMETER DeviceCode
    Sign in with the device-code flow instead of the browser.

.EXAMPLE
    .\Test-TenantHealth.ps1

.EXAMPLE
    .\Test-TenantHealth.ps1 -Customer 'Acme*'
#>

[CmdletBinding()]
param (
    [string[]]$Name,
    [string[]]$Customer,
    [string[]]$Group,
    [string[]]$TenantId,
    [ValidateRange(1, 20)][int]$ThrottleLimit = 5,

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string[]]$AccountName = @('cstech', 'csadmin', 'csbreakglass'),

    [switch]$DeviceCode
)

Import-Module (Join-Path $PSScriptRoot 'Toolkit/CSToolkit.psd1')
if (-not (Get-CSSession)) { Connect-CSPartner -DeviceCode:$DeviceCode | Out-Null }

$filter = @{}
foreach ($key in 'Name', 'Customer', 'Group', 'TenantId') {
    if ($PSBoundParameters.ContainsKey($key)) { $filter[$key] = $PSBoundParameters[$key] }
}
$tenants = @(Get-CSTenant @filter)
if ($tenants.Count -eq 0) { Write-Warning 'No tenants matched.'; return }
Write-Host "Checking $($tenants.Count) tenant(s)..." -ForegroundColor Cyan

# Runs in a separate process per tenant - inputs come in via -ArgumentList.
$work = {
    param($tenant, [string[]]$accountNames)

    $category = 'Accounts'
    $checkIdFor = { param($acct) "ACCT-$($acct.ToUpper())" }

    # One query for all accounts: startswith on UPN is supported without advanced query headers.
    $clauses = $accountNames | ForEach-Object { "startswith(userPrincipalName,'$_@')" }
    $uri = '/users?$select=id,displayName,userPrincipalName,accountEnabled&$filter=' + ($clauses -join ' or ')

    try {
        $users = @(Invoke-CSGraph $uri)
    }
    catch {
        $detail = if ($_.TargetObject.Status) { "$($_.TargetObject.Status) $($_.TargetObject.Code): $($_.TargetObject.Message)" } else { $_.Exception.Message }
        foreach ($acct in $accountNames) {
            New-CSResult -CheckId (& $checkIdFor $acct) -Category $category -Title "$acct@ account exists" -Status Error `
                -Expected 'Readable' -Actual "$($_.FullyQualifiedErrorId)" -Detail $detail
        }
        return
    }

    foreach ($acct in $accountNames) {
        $found    = @($users | Where-Object { $_.userPrincipalName -like "$acct@*" })
        $enabled  = @($found | Where-Object accountEnabled)
        $upns     = @($found | ForEach-Object { '{0}{1}' -f $_.userPrincipalName, $(if ($_.accountEnabled) { '' } else { ' (disabled)' }) })
        $severity = if ($acct -like '*breakglass*') { 'High' } else { 'Medium' }

        $status, $detail, $fix = if ($found.Count -eq 0) {
            'Fail', 'No account found on any tenant domain.', "Create $acct@<tenant domain>."
        }
        elseif ($enabled.Count -eq 0) {
            'Warn', 'Account exists but is disabled.', 'Enable the account (or confirm it is intentionally disabled).'
        }
        elseif ($found.Count -gt 1) {
            'Warn', "$($found.Count) matching accounts - expected one.", 'Remove or rename the duplicate.'
        }
        else {
            'Pass', $null, $null
        }

        New-CSResult -CheckId (& $checkIdFor $acct) -Category $category -Title "$acct@ account exists" -Status $status -Severity $severity `
            -Expected "$acct@<domain>, enabled" -Actual ($(if ($upns) { $upns -join '; ' } else { 'Missing' })) `
            -Affected $upns -Detail $detail -Remediation $fix
    }
}

$results = $tenants | Invoke-CSForEachTenant $work -ArgumentList (, $AccountName) -ThrottleLimit $ThrottleLimit | Expand-CSTenantRun

# Grid: one row per tenant, one column per account.
$grid = $results | Group-Object TenantId | ForEach-Object {
    $row = [ordered]@{ Tenant = $_.Group[0].Tenant; Customer = $_.Group[0].Customer }
    foreach ($acct in $AccountName) {
        $r = $_.Group | Where-Object CheckId -eq "ACCT-$($acct.ToUpper())" | Select-Object -First 1
        # Tenants that failed to run at all (RUN-* rows) have no per-account rows.
        $row[$acct] = if ($r) { $r.Status } else { ($_.Group | Select-Object -First 1).Status }
    }
    [pscustomobject]$row
}
$grid | Sort-Object Tenant | Format-Table -AutoSize

$problems = $results | Where-Object Status -ne 'Pass'
if ($problems) {
    Write-Host 'Needs attention:' -ForegroundColor Yellow
    $problems | Sort-Object Tenant, CheckId | Format-Table Tenant, Status, Title, Actual, Detail -AutoSize -Wrap
}
else {
    Write-Host 'All tenants have every standard account.' -ForegroundColor Green
}

$files = $results | Export-CSResult -Name 'TenantHealth'
Write-Host "Report: $($files -join ', ')" -ForegroundColor Green
