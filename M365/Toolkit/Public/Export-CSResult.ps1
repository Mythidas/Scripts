function Export-CSResult {
    <#
    .SYNOPSIS
        Writes results to timestamped CSV and/or JSON files under Data/Reports and returns the file paths.

    .DESCRIPTION
        CSV is flat, one row per result, with list columns joined by '; ' and structured values compressed to JSON, so it pivots cleanly.
        JSON keeps the full objects.

    .EXAMPLE
        $results | Export-CSResult -Name TenantHealth
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$InputObject,

        [string]$Name = 'Report',

        [string]$Path = (Join-Path $script:DataPath 'Reports'),

        [ValidateSet('Csv', 'Json')]
        [string[]]$Format = @('Csv', 'Json')
    )

    begin   { $rows = [System.Collections.Generic.List[object]]::new() }
    process { foreach ($item in $InputObject) { $rows.Add($item) } }
    end {
        if ($rows.Count -eq 0) { Write-Warning 'Export-CSResult: nothing to export.'; return }

        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

        if ('Csv' -in $Format) {
            $file = Join-Path $Path "$Name-$stamp.csv"
            $rows | ForEach-Object {
                $flat = [ordered]@{}
                foreach ($p in $_.PSObject.Properties) { $flat[$p.Name] = ConvertTo-CSFlatValue $p.Value }
                [pscustomobject]$flat
            } | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding utf8
            $file
        }

        if ('Json' -in $Format) {
            $file = Join-Path $Path "$Name-$stamp.json"
            $rows | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file -Encoding utf8
            $file
        }
    }
}
