function Get-CSResultSummary {
    <#
    .SYNOPSIS
        Rolls results up to one row per tenant with a count per status.

    .EXAMPLE
        $results | Get-CSResultSummary | Format-Table -AutoSize
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$InputObject
    )

    begin   { $rows = [System.Collections.Generic.List[object]]::new() }
    process { foreach ($item in $InputObject) { $rows.Add($item) } }
    end {
        foreach ($group in ($rows | Group-Object TenantId)) {
            $count = { param($s) @($group.Group | Where-Object Status -eq $s).Count }
            [pscustomobject]@{
                Tenant   = $group.Group[0].Tenant
                Customer = $group.Group[0].Customer
                Total    = $group.Count
                Fail     = & $count 'Fail'
                Warn     = & $count 'Warn'
                Error    = & $count 'Error'
                Pass     = & $count 'Pass'
                NA       = & $count 'NA'
            }
        }
    }
}
