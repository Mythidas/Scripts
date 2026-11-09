function New-CSResult {
    <#
    .SYNOPSIS
        Creates the standard result row every check (and any reporting script) emits. Tenant fields default to the current context.

    .DESCRIPTION
        Status: Pass | Fail | Warn | NA (does not apply to this tenant) | Error (could not be evaluated - e.g. no GDAP access).
        Error is deliberately separate from Fail so a missing permission never looks like a failed control.

    .EXAMPLE
        New-CSResult -CheckId CA-001 -Category ConditionalAccess -Title 'Require MFA for all users' -Status Fail `
            -Severity High -Expected 'Enabled policy' -Actual 'Policy is report-only' -Affected 'MFA - All users'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Fail', 'Warn', 'NA', 'Error')][string]$Status,
        [ValidateSet('Info', 'Low', 'Medium', 'High', 'Critical')][string]$Severity = 'Medium',
        $Expected,
        $Actual,
        [string[]]$Affected = @(),
        [string]$Detail,
        [string]$Remediation,
        $Tenant = $script:CSContext.Tenant
    )

    [pscustomobject]@{
        PSTypeName  = 'CS.Result'
        TenantId    = $Tenant.TenantId
        Tenant      = if ($Tenant.DisplayName) { $Tenant.DisplayName } else { $Tenant.DefaultDomain }
        Customer    = $Tenant.Customer
        CheckId     = $CheckId
        Category    = $Category
        Title       = $Title
        Status      = $Status
        Severity    = $Severity
        Expected    = $Expected
        Actual      = $Actual
        Affected    = $Affected
        Detail      = $Detail
        Remediation = $Remediation
        Timestamp   = (Get-Date).ToString('s')
    }
}
