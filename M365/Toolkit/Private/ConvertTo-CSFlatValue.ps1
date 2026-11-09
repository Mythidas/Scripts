function ConvertTo-CSFlatValue {
    <#
    .SYNOPSIS
        Flattens a value for a CSV cell: scalars as-is, lists of scalars joined with '; ', anything structured as compressed JSON.
    #>
    [CmdletBinding()]
    param ($Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string] -or $Value.GetType().IsPrimitive -or $Value -is [decimal]) { return $Value }
    if ($Value -is [datetime]) { return $Value.ToString('s') }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]) {
        $items = @($Value)
        if (-not ($items | Where-Object { $_ -isnot [string] -and -not $_.GetType().IsPrimitive })) { return $items -join '; ' }
    }
    $Value | ConvertTo-Json -Depth 8 -Compress
}
