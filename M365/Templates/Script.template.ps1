#Requires -Version 7.0

<#
.SYNOPSIS
    One-line description of the goal (what it accomplishes, not which customer it was written for).

.DESCRIPTION
    What it reads, what it changes, how it behaves on re-run. Read-only scripts say so.

.PARAMETER Customer
    Tenant selection - every tenant script takes the same four filters.

.EXAMPLE
    .\Script.template.ps1 -Customer 'Acme*' -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    # --- tenant selection (same on every script) ---
    [string[]]$Name,
    [string[]]$Customer,
    [string[]]$Group,
    [string[]]$TenantId,
    [ValidateRange(1, 20)][int]$ThrottleLimit = 5

    # --- script-specific inputs below; prefer input files / parameters over per-customer scripts ---
)

Import-Module (Join-Path $PSScriptRoot 'Toolkit/CSToolkit.psd1')
if (-not (Get-CSSession)) { Connect-CSPartner | Out-Null }

$filter = @{}
foreach ($key in 'Name', 'Customer', 'Group', 'TenantId') {
    if ($PSBoundParameters.ContainsKey($key)) { $filter[$key] = $PSBoundParameters[$key] }
}
$tenants = @(Get-CSTenant @filter)
if ($tenants.Count -eq 0) { Write-Warning 'No tenants matched.'; return }

# Runs in a separate process per tenant. Cannot see this script's variables - pass them via -ArgumentList.
# $WhatIfPreference is forwarded, so any cmdlet that supports ShouldProcess honours -WhatIf in there.
$work = {
    param($tenant)

    $users = Invoke-CSGraph '/users?$select=id,displayName&$top=999'
    foreach ($user in $users) {
        New-CSResult -CheckId 'EX-001' -Category Example -Title 'Example check' -Status Pass -Affected $user.displayName
    }
}

$results = $tenants | Invoke-CSForEachTenant $work -ThrottleLimit $ThrottleLimit | Expand-CSTenantRun
$results | Get-CSResultSummary | Format-Table -AutoSize
$results | Export-CSResult -Name 'Example'
