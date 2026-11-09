function Expand-CSTenantRun {
    <#
    .SYNOPSIS
        Flattens Invoke-CSForEachTenant run objects into result rows, so a tenant that failed outright shows up in the report.

    .DESCRIPTION
        Result objects emitted by the script block are passed through. Tenants that Failed or TimedOut add an Error row (RUN-001);
        tenants that finished with non-terminating errors add a Warn row (RUN-002). Without this a tenant whose token could not be
        minted (no GDAP, consent missing) would silently vanish from the output.

    .EXAMPLE
        Get-CSTenant | Invoke-CSForEachTenant { param($t) Test-Something } | Expand-CSTenantRun | Export-CSResult -Name Something
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$Run
    )

    process {
        foreach ($r in $Run) {
            $tenant = [pscustomobject]@{ TenantId = $r.TenantId; DisplayName = $r.Tenant; Customer = $r.Customer }

            $r.Output | Where-Object { $_.PSObject.Properties['CheckId'] -and $_.PSObject.Properties['Status'] }

            if ($r.Status -in 'Failed', 'TimedOut') {
                New-CSResult -Tenant $tenant -CheckId 'RUN-001' -Category 'Run' -Title 'Tenant run completed' -Status Error -Severity High `
                    -Expected 'Succeeded' -Actual $r.Status -Detail (($r.Errors | Select-Object -First 3) -join ' | ')
            }
            elseif ($r.Status -eq 'SucceededWithErrors') {
                New-CSResult -Tenant $tenant -CheckId 'RUN-002' -Category 'Run' -Title 'Tenant run completed without errors' -Status Warn -Severity Medium `
                    -Expected 'Succeeded' -Actual $r.Status -Detail (($r.Errors | Select-Object -First 3) -join ' | ')
            }
        }
    }
}
