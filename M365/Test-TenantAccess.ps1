#Requires -Version 7.0

<#
.SYNOPSIS
    Checks, per tenant, what your GDAP sign-in can actually read: one row per tenant per Graph endpoint.

.DESCRIPTION
    Run this first (and again whenever GDAP roles or consent change). It signs in once to the partner tenant, mints a delegated token
    for every selected tenant, and probes the endpoints the health checks will depend on. The result tells you, per tenant, which
    checks will work and which will report "Error: insufficient access" instead of Pass/Fail.

    Status per probe:  Pass = readable   Error = blocked or unavailable (403 = missing GDAP role / consent / licence, see Detail)
    A tenant whose token cannot be minted at all gets one RUN-001 row (typically consent for the sign-in client is missing there).

    Output: Data/Reports/TenantAccess-<timestamp>.csv and .json

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

.PARAMETER DeviceCode
    Sign in with the device-code flow instead of the browser.

.EXAMPLE
    .\Test-TenantAccess.ps1

.EXAMPLE
    .\Test-TenantAccess.ps1 -Customer 'Acme*' -ThrottleLimit 2
#>

[CmdletBinding()]
param (
    [string[]]$Name,
    [string[]]$Customer,
    [string[]]$Group,
    [string[]]$TenantId,
    [ValidateRange(1, 20)][int]$ThrottleLimit = 5,
    [switch]$DeviceCode
)

Import-Module (Join-Path $PSScriptRoot 'Toolkit/CSToolkit.psd1')

if (-not (Get-CSSession)) { Connect-CSPartner -DeviceCode:$DeviceCode | Out-Null }

$filter  = @{}
foreach ($key in 'Name', 'Customer', 'Group', 'TenantId') {
    if ($PSBoundParameters.ContainsKey($key)) { $filter[$key] = $PSBoundParameters[$key] }
}
$tenants = @(Get-CSTenant @filter)
if ($tenants.Count -eq 0) { Write-Warning 'No tenants matched.'; return }
Write-Host "Probing $($tenants.Count) tenant(s)..." -ForegroundColor Cyan

$probeScript = {
    param($tenant)

    $ctx = Get-CSContext
    $claims = ConvertFrom-CSJwt $ctx.AccessToken
    New-CSResult -CheckId 'ACCESS-00' -Category Access -Title 'Delegated token' -Status Pass -Severity Info `
        -Actual $claims.scp -Detail "roles/wids: $(@($claims.wids).Count); signed in as $($claims.upn)"

    $probes = @(
        @{ Id = 'ACCESS-01'; Title = 'Organization';                  Uri = '/organization?$select=id,displayName' }
        @{ Id = 'ACCESS-02'; Title = 'Users';                         Uri = '/users?$top=1&$select=id' }
        @{ Id = 'ACCESS-03'; Title = 'Subscribed SKUs / licences';    Uri = '/subscribedSkus?$select=id' }
        @{ Id = 'ACCESS-04'; Title = 'Conditional Access policies';   Uri = '/identity/conditionalAccess/policies?$top=1' }
        @{ Id = 'ACCESS-05'; Title = 'Directory role assignments';    Uri = '/roleManagement/directory/roleAssignments?$top=1' }
        @{ Id = 'ACCESS-06'; Title = 'Sign-in activity (needs P1)';   Uri = '/users?$top=1&$select=id,signInActivity' }
        @{ Id = 'ACCESS-07'; Title = 'MFA registration report';       Uri = '/reports/authenticationMethods/userRegistrationDetails?$top=1' }
        @{ Id = 'ACCESS-08'; Title = 'Authentication methods policy'; Uri = '/policies/authenticationMethodsPolicy' }
        @{ Id = 'ACCESS-09'; Title = 'Intune managed devices';        Uri = '/deviceManagement/managedDevices?$top=1&$select=id' }
        @{ Id = 'ACCESS-10'; Title = 'Secure score';                  Uri = '/security/secureScores?$top=1' }
        @{ Id = 'ACCESS-11'; Title = 'PIM role eligibility (needs P2)'; Uri = '/roleManagement/directory/roleEligibilitySchedules?$top=1' }
    )

    foreach ($probe in $probes) {
        try {
            Invoke-CSGraph $probe.Uri -NoPaging | Out-Null
            New-CSResult -CheckId $probe.Id -Category Access -Title $probe.Title -Status Pass -Severity Info
        }
        catch {
            $detail = if ($_.TargetObject.Status) { "$($_.TargetObject.Status) $($_.TargetObject.Code): $($_.TargetObject.Message)" } else { $_.Exception.Message }
            New-CSResult -CheckId $probe.Id -Category Access -Title $probe.Title -Status Error -Severity Info `
                -Expected 'Readable' -Actual "$($_.FullyQualifiedErrorId)" -Detail $detail
        }
    }
}

$results = $tenants | Invoke-CSForEachTenant $probeScript -ThrottleLimit $ThrottleLimit | Expand-CSTenantRun

$results | Get-CSResultSummary | Sort-Object Tenant | Format-Table Tenant, Customer, @{ n = 'Probes'; e = 'Total' }, Pass, Error -AutoSize

$blocked = $results | Where-Object { $_.Status -eq 'Error' -and $_.CheckId -ne 'ACCESS-00' }
if ($blocked) {
    Write-Host 'Blocked probes by endpoint (how many tenants cannot read it):' -ForegroundColor Yellow
    $blocked | Group-Object CheckId | Sort-Object Name |
        Select-Object @{ n = 'Probe'; e = 'Name' }, Count, @{ n = 'Title'; e = { $_.Group[0].Title } } | Format-Table -AutoSize
}

$files = $results | Export-CSResult -Name 'TenantAccess'
Write-Host "Report: $($files -join ', ')" -ForegroundColor Green
